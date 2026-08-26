import Foundation

/// Installs the extension that reports Pi's session state to the sidebar.
///
/// **The only installer here that does not edit a configuration file.** Pi's
/// hook mechanism is not declarative: it loads TypeScript modules from
/// `~/.pi/agent/extensions`, each exporting a factory that subscribes to
/// events. So there is nothing to merge into and nothing of the reader's to
/// preserve — the extension is one file, and it is entirely Phantom's. Install
/// writes it, uninstall deletes it, and staleness is the file differing from
/// what this build ships.
///
/// That also makes this the safest of the five and the one with the least to
/// say about failure: no other program's settings can be corrupted by getting
/// it wrong.
///
/// **No package to publish.** Pi auto-discovers `*.ts` in that directory, and
/// Node's built-ins are available inside an extension, so the file needs no
/// dependency, no `package.json` and no npm entry. The type import Pi's own
/// documentation shows is deliberately left out for the same reason: it is
/// erased at run time, and omitting it means the file cannot fail to resolve.
@MainActor
enum PiHooksInstaller {
    static let extensionName = "phantom.ts"

    /// Pi's global extension directory. The project-local `.pi/extensions`
    /// is not used: a hook that reports which tab an agent is running in is a
    /// fact about this app, not about one repository, and installing it per
    /// project would mean installing it again for every project.
    nonisolated static var extensionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
    }

    static var extensionURL: URL { extensionsDir.appendingPathComponent(extensionName) }

    /// The events this subscribes to, for the settings pane to name. Kept
    /// beside the source below so the two cannot drift.
    ///
    /// No permission event, and none is missing: Pi's core does not prompt.
    /// A confirmation in Pi comes from an extension calling `ctx.ui.confirm`
    /// inside its own `tool_call` handler, so an agent waiting on one is a
    /// state only that extension knows about. Adding a `tool_call` handler
    /// here to find out would mean this extension gating tool calls, which is
    /// a different job from reporting what the tab is doing.
    static let events = [
        "session_start", "agent_start", "tool_execution_start",
        "agent_end", "session_shutdown",
    ]

    /// The extension, as it is written to disk.
    ///
    /// `session_start` carries identity rather than activity, so it reports an
    /// empty state — a tab with an agent in it that is doing nothing draws no
    /// indicator — and it is where the session id is captured.
    ///
    /// The id is the **UUID inside** the session file's name, and getting
    /// that wrong is how this first shipped broken.
    ///
    /// Pi names a session `<timestamp>_<uuid>.jsonl` and documents
    /// `--session <path|id>` as taking a path or a partial UUID. The whole
    /// stem is neither: `pi --session 2026-08-25T21-29-13-505Z_01a03…`
    /// answers "No session found matching" and starts a fresh conversation, so
    /// a restored tab silently lost its history.
    ///
    /// The path would work and cannot be used:
    /// `AgentTabRecord.sanitized(sessionID:)` refuses anything holding a
    /// slash, so it would be written, dropped on read, and the tab would
    /// resume with `--continue` while its file looked like it held an id.
    static let source = #"""
    // Reports Pi session state to the Phantom sidebar.
    //
    // Managed by Phantom. Delete it from the app's Settings rather than by
    // hand, so the app stops believing it is installed.
    import { writeFileSync, renameSync, unlinkSync } from "node:fs";

    export default function (pi) {
      const stateFile = process.env.GHOSTTY_TAB_STATE_FILE;
      if (!stateFile) return;

      let session = "";

      // The id is the session file's own name. A path would be refused by the
      // app on read, and a leading dash is a flag rather than an id once it
      // reaches `pi --session`.
      const idFrom = (file) => {
        if (!file) return "";
        const base = String(file).split("/").pop() || "";
        const stem = base.replace(/\.[^.]*$/, "");
        if (!stem) return "";

        // The UUID pi will match on, wherever it sits in the name. Falling
        // back to the whole stem rather than to nothing keeps a naming scheme
        // this does not recognise working the way it did.
        const uuid = stem.match(
          /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
        );
        const id = uuid ? uuid[0] : stem;

        // A leading dash is a flag rather than an id once it reaches
        // `pi --session`.
        if (id.startsWith("-")) return "";
        return /^[A-Za-z0-9._-]+$/.test(id) ? id : "";
      };

      // A temp name private to this process, then a rename. A fixed name is one
      // path shared by everything writing this tab, and two writers truncating
      // it interleave their bytes — which is how a session line arrives cut in
      // half. The app reads only entries whose whole name is a UUID, so this
      // name is never mistaken for a state file.
      const report = (state) => {
        const temp = stateFile + "." + process.pid + ".tmp";
        let body = state + "\nagent=pi\n";
        if (session) body += "session=" + session + "\n";
        try {
          writeFileSync(temp, body);
          renameSync(temp, stateFile);
        } catch (error) {
          try {
            unlinkSync(temp);
          } catch (ignored) {
            // Nothing to clean up, which is the common case.
          }
        }
      };

      pi.on("session_start", async (_event, ctx) => {
        const file = ctx && ctx.sessionManager && ctx.sessionManager.getSessionFile
          ? ctx.sessionManager.getSessionFile()
          : null;
        session = idFrom(file) || session;
        report("");
      });

      pi.on("agent_start", async () => report("working"));
      pi.on("tool_execution_start", async () => report("working"));
      pi.on("agent_end", async () => report("done"));
      pi.on("session_shutdown", async () => report("ended"));
    }
    """#

    static private(set) var lastError: String?

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: extensionURL.path)
    }

    /// True when the file on disk is not the one this build ships. Read rather
    /// than compared by date: a reader who edited it has a file that works and
    /// is not ours, and rewriting it is the honest thing to do only because
    /// `repairIfStale` runs on an installation the reader already asked for.
    static var isStale: Bool {
        guard let onDisk = try? String(contentsOf: extensionURL, encoding: .utf8) else {
            return false
        }
        return onDisk != source
    }

    static func install() -> Bool {
        lastError = nil
        do {
            try FileManager.default.createDirectory(
                at: extensionsDir, withIntermediateDirectories: true)
            try source.write(to: extensionURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            lastError = "could not write \(extensionURL.path): \(error.localizedDescription)"
            return false
        }
    }

    static func uninstall() -> Bool {
        lastError = nil
        guard isInstalled else { return true }
        do {
            try FileManager.default.removeItem(at: extensionURL)
            return true
        } catch {
            lastError = "could not remove \(extensionURL.path): \(error.localizedDescription)"
            return false
        }
    }

    static func repairIfStale() -> Bool {
        guard isInstalled, isStale else { return false }
        return install()
    }
}
