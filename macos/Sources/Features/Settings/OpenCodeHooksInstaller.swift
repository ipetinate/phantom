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

    /// ⚠️ The session-id half of this plugin is written blind: OpenCode is
    /// not installed on the machine this was written on, so which property
    /// an event actually carries the id in could not be checked. The lookup
    /// below tries the plausible spellings and settles for none of them —
    /// in which case the file keeps its state line, exactly as before, and
    /// the tab resumes with `opencode --continue`.
    ///
    /// Not private so a test can at least put it through a parser: nothing
    /// here can run OpenCode, but shipping a plugin that does not parse is a
    /// failure worth catching without it.
    static let pluginBody = #"""
    import { writeFileSync, renameSync } from "fs";

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

    function state(value) {
      const file = process.env.GHOSTTY_TAB_STATE_FILE;
      if (!file) return;
      // State stays alone on the first line: a Phantom old enough to read
      // only that line keeps reading this file correctly.
      const lines = [value, "agent=opencode"];
      if (sessionId) lines.push(`session=${sessionId}`);
      const body = lines.join("\n") + "\n";
      // OpenCode can emit busy -> idle -> idle in one turn. Serialize the
      // atomic writes so a late busy event cannot leave Phantom spinning.
      writeChain = writeChain.then(() => {
        try {
          const tmp = `${file}.tmp`;
          writeFileSync(tmp, body, "utf8");
          renameSync(tmp, file);
        } catch {}
      }).catch(() => {});
    }

    function statusType(event) {
      return event?.properties?.status?.type || event?.status?.type || event?.status || "";
    }

    export const PhantomPlugin = async () => ({
      event: async ({ event }) => {
        remember(sessionIdFrom(event));
        const type = event?.type || "";
        if (type === "session.status") {
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
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func uninstall() -> Bool {
        do {
            try FileManager.default.removeItem(at: pluginURL)
            return true
        } catch CocoaError.fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }
}
