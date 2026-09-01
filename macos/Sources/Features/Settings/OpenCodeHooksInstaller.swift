import Foundation

/// Installs a small native OpenCode plugin in the user's OpenCode config.
/// OpenCode plugins receive lifecycle events and write the same atomic state
/// file consumed by TabStateCenter.
@MainActor
enum OpenCodeHooksInstaller {
    static let pluginName = "phantom-integration.js"

    static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode", isDirectory: true)
    }

    static var pluginURL: URL {
        configDir.appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginName)
    }

    /// The session-id half of this plugin has since been run against a real
    /// OpenCode: it reports ids of the shape `ses_fff4fad66ffew9XwYrbmxeGqEb`,
    /// and one of the spellings below does find them. Which one is left
    /// unpinned on purpose — the events are the plugin API's, not a contract
    /// with Phantom, and trying the alternatives costs a property access each.
    /// All of them failing stays a supported outcome: the file keeps its state
    /// line, exactly as before, and the tab resumes without an id — from
    /// `AgentSessionStore` if the session is still in OpenCode's database, and
    /// from `opencode --continue` if it is not.
    ///
    /// Not private so a test can put it through a parser: shipping a plugin
    /// that does not parse is a failure worth catching without OpenCode in the
    /// room to catch it.
    static let pluginBody = #"""
    import { writeFileSync, renameSync, unlinkSync, readFileSync } from "fs";

    let writeChain = Promise.resolve();
    let sessionId = "";

    // The id ends up typed at a shell prompt after `opencode --session`, so
    // anything a shell would read as more than one word is refused — and so
    // is anything starting with a dash, which would arrive there as a flag.
    function remember(candidate) {
      if (typeof candidate === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(candidate)) {
        sessionId = candidate;
      }
    }

    function sessionIdFrom(event) {
      const props = event?.properties || {};
      return props.sessionID || props.sessionId || props.session_id ||
        props.info?.sessionID || props.info?.id || props.session?.id || "";
    }

    // A subagent runs in a session of its own, a child of the tab's, and
    // resuming by a child's id opens that thread rather than the conversation
    // the tab was holding. `Session.parentID` is what separates them, and the
    // events that carry a whole `info` object are the ones that can be asked.
    function isSubSession(event) {
      const info = event?.properties?.info;
      return Boolean(info && (info.parentID || info.parentId));
    }

    // The id already on record, for a process that has not learned one yet.
    //
    // Every write here rewrites the whole file, so without this the first write
    // of a freshly loaded plugin drops the `session=` line that was in it — and
    // several of the handlers below report a state without any event having
    // carried an id first. The write that follows a restore is exactly that
    // shape, and the id it would drop is the only record of which conversation
    // the tab was resumed into. Passing it back through `remember` rather than
    // straight into the file means the value read off disk faces the same
    // filter a value off the wire does, so a corrupt line cannot be copied
    // forward indefinitely.
    function carriedSession(file) {
      try {
        const carried = readFileSync(file, "utf8")
          .split("\n")
          .find((line) => line.startsWith("session="));
        return carried ? carried.slice("session=".length).trim() : "";
      } catch {
        return "";
      }
    }

    function state(value) {
      const file = process.env.GHOSTTY_TAB_STATE_FILE;
      if (!file) return;
      if (!sessionId) remember(carriedSession(file));
      // State stays alone on the first line: a Phantom old enough to read
      // only that line keeps reading this file correctly.
      const lines = [value, "agent=opencode"];
      if (sessionId) lines.push(`session=${sessionId}`);
      const body = lines.join("\n") + "\n";
      // OpenCode can emit busy -> idle -> idle in one turn. Serialize the
      // atomic writes so a late busy event cannot leave Phantom spinning.
      writeChain = writeChain.then(() => {
        // A temp name private to this process. Serializing the chain orders
        // this plugin's own writes, and does nothing about anyone else's: a
        // fixed `.tmp` is one path shared with whatever else writes this tab —
        // a Claude or Codex hook in the same terminal, another integration on
        // the same events — and two writers truncating that one file
        // interleave their bytes, so the rename that wins carries the mixture
        // and a `session=` line comes back cut in half.
        //
        // The name still cannot be mistaken for a state file: TabStateCenter
        // reads only entries whose whole name parses as a UUID.
        const tmp = `${file}.${process.pid}.tmp`;
        try {
          writeFileSync(tmp, body, "utf8");
          renameSync(tmp, file);
        } catch {
          try { unlinkSync(tmp); } catch {}
        }
      }).catch(() => {});
    }

    function statusType(event) {
      return event?.properties?.status?.type || event?.status?.type || event?.status || "";
    }

    export const PhantomPlugin = async () => ({
      event: async ({ event }) => {
        if (!isSubSession(event)) remember(sessionIdFrom(event));
        const type = event?.type || "";
        if (type === "session.created") {
          // OpenCode's answer to a session-start hook. It carries the id in
          // `properties.sessionID` on one SDK generation and
          // `properties.info.id` on the other, both of which `sessionIdFrom`
          // already reads, and it fires before the user has asked for
          // anything — so the tab holds its id from the moment it opens
          // rather than from its first prompt.
          //
          // Written with no state word: a session that has just been created
          // is not working, and this is the record saying which conversation
          // the tab holds, not what it is doing.
          state("");
        } else if (type === "session.status") {
          const status = statusType(event);
          if (status === "busy" || status === "retry") state("working");
          else if (status === "idle") state("done");
        } else if (type === "session.idle") {
          state("done");
        } else if (
          type === "session.error" ||
          type === "permission.asked" ||
          type === "question.asked"
        ) {
          state("awaiting");
        }
      },
      "chat.message": async (_input, output) => {
        remember(output?.message?.sessionID);
        state("working");
      },
      "command.execute.before": async () => state("working"),
      "tool.execute.before": async () => state("working"),
      "permission.ask": async () => state("awaiting"),
    });
    """#

    /// Human-readable detail of the last failure, for the settings UI.
    ///
    /// The five other hooks installers have had one from the start; this one
    /// answered `false` and said nothing, so a plugin that could not be written
    /// — a read-only `~/.config`, a directory that is a file — looked exactly
    /// like a button that does nothing. Named after the stage, as
    /// `ClaudeHooksInstaller.fail` names its own.
    static private(set) var lastError: String?

    private static func fail(_ stage: String, _ error: Error? = nil) -> Bool {
        lastError = error.map { "\(stage): \($0.localizedDescription)" } ?? stage
        return false
    }

    /// True when the installed plugin is not the one this build ships. See
    /// `ClaudeHooksInstaller.isStale` for why `isInstalled` cannot answer it.
    static var isStale: Bool {
        guard let onDisk = try? String(contentsOf: pluginURL, encoding: .utf8)
        else { return false }
        return onDisk != pluginBody
    }

    /// Rewrites the plugin when it is not this build's. The file is generated
    /// and never edited by hand, so there is nothing of anyone else's in it.
    @discardableResult
    static func repairIfStale() -> Bool {
        guard isInstalled, isStale else { return false }
        return (try? pluginBody.write(to: pluginURL, atomically: true, encoding: .utf8)) != nil
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: pluginURL.path)
    }

    @discardableResult
    static func install() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: pluginURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pluginBody.write(to: pluginURL, atomically: true, encoding: .utf8)
            lastError = nil
            return true
        } catch {
            return fail("writing the plugin", error)
        }
    }

    @discardableResult
    static func uninstall() -> Bool {
        do {
            try FileManager.default.removeItem(at: pluginURL)
            lastError = nil
            return true
        } catch CocoaError.fileNoSuchFile {
            lastError = nil
            return true
        } catch {
            return fail("removing the plugin", error)
        }
    }
}
