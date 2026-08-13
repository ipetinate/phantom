import Foundation

/// Installs Codex lifecycle hooks without replacing hooks owned by Codex or
/// another integration. Each hook writes the same per-terminal state file
/// used by the sidebar's Claude integration.
@MainActor
enum CodexHooksInstaller {
    static let scriptName = "phantom-tab-state.sh"
    /// Codex can be configured with CODEX_HOME (and this installation uses
    /// ~/.codex-cli). Resolve it at use time so the settings screen and the
    /// installer always target the same home as the running Codex binary.
    static var codexDir: URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let cliHome = home.appendingPathComponent(".codex-cli", isDirectory: true)
        if FileManager.default.fileExists(atPath: cliHome.path) {
            return cliHome
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    static var scriptURL: URL { codexDir.appendingPathComponent(scriptName) }
    static var settingsURL: URL { codexDir.appendingPathComponent("hooks.json") }

    static let eventStates: [(event: String, state: String)] = [
        ("UserPromptSubmit", "working"),
        ("PreToolUse", "working"),
        ("PostToolUse", "working"),
        ("PermissionRequest", "awaiting"),
        ("Stop", "done"),
        ("SessionEnd", "ended"),
    ]

    /// ⚠️ The id extraction here is written blind. Claude Code documents a
    /// JSON payload on stdin with a `session_id`; Codex's hook payload was
    /// not available to check, and Codex is not installed on the machine
    /// this was written on, so the key names below are candidates rather
    /// than facts. Every one of them failing is a supported outcome: the
    /// script then reports the state alone, exactly as it did before, and
    /// the tab resumes with `codex resume --last`.
    static let scriptBody = #"""
    #!/bin/bash
    # Reports Codex session state to the Phantom sidebar.
    [ -n "$GHOSTTY_TAB_STATE_FILE" ] || exit 0
    STATE="$1"

    PAYLOAD=""
    if [ ! -t 0 ]; then
      PAYLOAD=$(cat 2>/dev/null)
    fi
    FLAT=$(printf '%s' "$PAYLOAD" | tr -d '\n')

    SESSION=""
    for KEY in session_id sessionId conversation_id conversationId thread_id; do
      [ -n "$SESSION" ] && break
      SESSION=$(printf '%s' "$FLAT" \
        | sed -n "s/.*\"$KEY\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")
    done

    # A dash-leading id is a flag, not an id, once it reaches `codex resume`.
    case "$SESSION" in
      -*|*[!A-Za-z0-9._-]*) SESSION="" ;;
    esac

    if [ -z "$SESSION" ] && [ -f "$GHOSTTY_TAB_STATE_FILE" ]; then
      SESSION=$(sed -n 's/^session=//p' "$GHOSTTY_TAB_STATE_FILE" | head -n 1)
    fi

    {
      printf '%s\nagent=codex\n' "$STATE"
      if [ -n "$SESSION" ]; then
        printf 'session=%s\n' "$SESSION"
      fi
    } > "$GHOSTTY_TAB_STATE_FILE.tmp" \
      && mv "$GHOSTTY_TAB_STATE_FILE.tmp" "$GHOSTTY_TAB_STATE_FILE"
    exit 0
    """#

    static private(set) var lastError: String?

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: scriptURL.path)
            && isRegistered(in: readSettings())
    }

    @discardableResult
    static func install() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: codexDir, withIntermediateDirectories: true
            )
            try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
            )
        } catch {
            return fail("writing Codex hook script", error)
        }

        guard var settings = readSettings() else {
            return fail("hooks.json is unreadable or isn't a JSON object")
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, state) in eventStates {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { commands(in: $0).contains { $0.contains(scriptName) } }
            entries.append([
                "hooks": [[
                    "type": "command",
                    "command": "'\(scriptURL.path)' \(state)"
                ]]
            ])
            hooks[event] = entries
        }
        settings["hooks"] = hooks
        guard writeSettings(settings), isInstalled else {
            return fail("Codex hooks were written but could not be verified")
        }
        lastError = nil
        return true
    }

    @discardableResult
    static func uninstall() -> Bool {
        guard var settings = readSettings() else {
            return fail("hooks.json is unreadable or isn't a JSON object")
        }
        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard var entries = value as? [[String: Any]] else { continue }
                entries.removeAll { commands(in: $0).contains { $0.contains(scriptName) } }
                hooks[event] = entries
            }
            settings["hooks"] = hooks
        }
        try? FileManager.default.removeItem(at: scriptURL)
        guard writeSettings(settings), !isRegistered(in: readSettings()) else {
            return fail("removing Codex hooks")
        }
        lastError = nil
        return true
    }

    /// Reads `hooks.json`, telling "there is nothing here yet" apart from
    /// "there is something here this doesn't understand".
    ///
    /// An empty dictionary means the file is absent or empty, which the
    /// installer may safely create. Nil means a file exists that isn't a
    /// JSON object — hand-edited, half-written, a top-level array — and the
    /// installer must leave it alone. Collapsing the two is what let a
    /// single malformed byte turn the user's whole Codex configuration into
    /// Phantom's six hooks, atomically and while reporting success.
    static func readSettings(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? nil : [:]
        }
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func readSettings() -> [String: Any]? {
        readSettings(at: settingsURL)
    }

    private static func writeSettings(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        do {
            try data.write(to: settingsURL, options: .atomic)
            return true
        } catch { return false }
    }

    private static func commands(in entry: [String: Any]) -> [String] {
        (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
    }

    private static func isRegistered(in settings: [String: Any]?) -> Bool {
        let hooks = settings?["hooks"] as? [String: Any] ?? [:]
        return eventStates.allSatisfy { event, _ in
            (hooks[event] as? [[String: Any]] ?? []).contains {
                commands(in: $0).contains { $0.contains(scriptName) }
            }
        }
    }

    private static func fail(_ message: String, _ error: Error? = nil) -> Bool {
        lastError = error.map { "\(message): \($0.localizedDescription)" } ?? message
        return false
    }
}
