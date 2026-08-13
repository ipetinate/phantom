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

    private static let pluginBody = #"""
    import { writeFileSync, renameSync } from "fs";

    let writeChain = Promise.resolve();

    function state(value) {
      const file = process.env.GHOSTTY_TAB_STATE_FILE;
      if (!file) return;
      // OpenCode can emit busy -> idle -> idle in one turn. Serialize the
      // atomic writes so a late busy event cannot leave Phantom spinning.
      writeChain = writeChain.then(() => {
        try {
          const tmp = `${file}.tmp`;
          writeFileSync(tmp, value, "utf8");
          renameSync(tmp, file);
        } catch {}
      }).catch(() => {});
    }

    function statusType(event) {
      return event?.properties?.status?.type || event?.status?.type || event?.status || "";
    }

    export const PhantomPlugin = async () => ({
      event: async ({ event }) => {
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
      "chat.message": async () => state("working"),
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
