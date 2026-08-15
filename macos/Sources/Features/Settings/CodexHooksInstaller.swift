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
    ///
    /// Not isolated to the main actor, unlike the rest of the installer:
    /// `AgentSessionStore` needs the same home to find the session rollouts,
    /// and it runs off the main thread precisely so that reading them cannot
    /// stall a restore. Two resolvers would be one resolver too many — the
    /// installer writing hooks into a home the reader never looks at is a
    /// silent failure with no symptom to chase.
    nonisolated static var codexDir: URL {
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

    /// Hook events and the state each one reports.
    ///
    /// PascalCase, because that is what `hooks.json` takes — confirmed against
    /// the file Codex itself maintains, whose keys read `SessionStart`,
    /// `UserPromptSubmit`, `PostToolUse`. The snake_case spellings
    /// (`session_start`) are Codex's *internal* normalization and show up only
    /// as bookkeeping keys under `[hooks.state]` in `config.toml`, of the form
    /// `"…/hooks.json:session_start:0:0"`. Writing snake_case into `hooks.json`
    /// would register nothing.
    ///
    /// `SessionStart` reports no state. It fires when a session begins, before
    /// any prompt, so the tab holds its id from the moment it opens — the one
    /// thing that keeps a restore off `codex resume --last` and lets two tabs
    /// in one directory be told apart. But a session that has only just begun
    /// is not *working*: an empty first line records identity without lighting
    /// an indicator, which is the same shape `TabStateCenter.recordAgentStart`
    /// writes from the app side.
    ///
    /// That `[hooks.state]` table is also the evidence the event fires at all:
    /// it holds a `session_start` entry, written by another integration that
    /// had registered for it before Phantom did.
    static let eventStates: [(event: String, state: String)] = [
        ("SessionStart", ""),
        ("UserPromptSubmit", "working"),
        ("PreToolUse", "working"),
        ("PostToolUse", "working"),
        ("PermissionRequest", "awaiting"),
        ("Stop", "done"),
        ("SessionEnd", "ended"),
    ]

    /// The registered command line for one event. An empty state passes no
    /// argument rather than an empty one — see `ClaudeHooksInstaller.command`
    /// for why the distinction matters.
    static func command(for state: String) -> String {
        state.isEmpty ? "'\(scriptURL.path)'" : "'\(scriptURL.path)' \(state)"
    }

    /// The id extraction here has since been run against a real Codex: the
    /// payload does carry the session id, of the same UUID shape Claude Code
    /// uses, and the loop below finds it. The extra key names stay because
    /// they cost a `sed` each and the payload is Codex's to change.
    ///
    /// What the events registered above cannot cover is a session nobody has
    /// spoken to yet. Every one of them needs the user to have said something,
    /// so a tab where the agent is up but unprompted reaches no hook at all and
    /// its file holds no id — the gap `AgentSessionStore` closes by reading the
    /// rollout Codex itself wrote at startup. Codex does have a `SessionStart`
    /// event and adding it here would report the id sooner, but only for
    /// somebody who reinstalls the hooks afterwards, so it is an improvement on
    /// top of the store rather than instead of it. All of this failing is still
    /// a supported outcome: the script reports the state alone and the tab
    /// resumes with `codex resume --last`.
    static let scriptBody = #"""
    #!/bin/bash
    # Reports Codex session state to the Phantom sidebar.
    [ -n "$GHOSTTY_TAB_STATE_FILE" ] || exit 0
    # Absent on purpose for SessionStart, which reports identity rather than
    # activity: no argument means an empty first line, and no indicator.
    STATE="$1"

    PAYLOAD=""
    if [ ! -t 0 ]; then
      PAYLOAD=$(cat 2>/dev/null)
    fi
    FLAT=$(printf '%s' "$PAYLOAD" | tr -d '\n')

    # A dash-leading id is a flag, not an id, once it reaches `codex resume`.
    #
    # A function because every source of an id goes through it: each candidate
    # key, and the value carried forward out of the file. Filtering only the
    # payload left a corrupt carried value to be copied forward on every later
    # event, so one bad write stuck to the tab permanently — the file still
    # looked like it held an id, and the resume stayed quietly imprecise.
    sanitize_session() {
      case "$1" in
        ""|-*|*[!A-Za-z0-9._-]*) return 0 ;;
        *) printf '%s' "$1" ;;
      esac
    }

    # The FIRST match per key, not the last. A `sed` opening with `.*` is
    # greedy and lands on the LAST occurrence in the payload — and tool events
    # nest a session id inside `tool_input`/`tool_response`, where a subagent
    # call or an MCP tool reports one of its own. That nested id is a valid
    # UUID, so the filter passes it and nothing downstream objects; the tab then
    # resumes a conversation it never held. The session's own id is a top-level
    # field in every payload these CLIs emit, so it precedes anything nested.
    #
    # Filtering inside the loop rather than after it, so that a key which
    # matches something unusable does not shadow the keys still untried.
    SESSION=""
    for KEY in session_id sessionId conversation_id conversationId thread_id; do
      [ -n "$SESSION" ] && break
      SESSION=$(sanitize_session "$(printf '%s' "$FLAT" \
        | grep -o "\"$KEY\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -n 1 \
        | sed 's/.*"\([^"]*\)"$/\1/')")
    done

    if [ -z "$SESSION" ] && [ -f "$GHOSTTY_TAB_STATE_FILE" ]; then
      SESSION=$(sanitize_session "$(sed -n 's/^session=//p' \
        "$GHOSTTY_TAB_STATE_FILE" | head -n 1)")
    fi

    # A temp name private to this invocation. A fixed `.tmp` is one path shared
    # by everything writing this tab — parallel tool calls, a second agent in
    # the same terminal, another integration on the same events — and two of
    # them truncating that one file interleaves their bytes. The rename that
    # wins carries the mixture, which is how a `session=` line arrives cut in
    # half; the one that loses renames a file the winner already took, so its
    # error is dropped rather than surfaced, and its fragment is removed.
    #
    # The name still cannot be mistaken for a state file: TabStateCenter reads
    # only entries whose whole name parses as a UUID, and this one does not.
    TMP="$GHOSTTY_TAB_STATE_FILE.$$.tmp"

    {
      printf '%s\nagent=codex\n' "$STATE"
      if [ -n "$SESSION" ]; then
        printf 'session=%s\n' "$SESSION"
      fi
    } > "$TMP" \
      && mv "$TMP" "$GHOSTTY_TAB_STATE_FILE" 2>/dev/null \
      || rm -f "$TMP"
    exit 0
    """#

    static private(set) var lastError: String?

    /// True when the installed script file is not the one this build ships. See
    /// `ClaudeHooksInstaller.isScriptStale` for why `isInstalled` cannot answer
    /// it.
    static var isScriptStale: Bool {
        guard let onDisk = try? String(contentsOf: scriptURL, encoding: .utf8)
        else { return false }
        return onDisk != scriptBody
    }

    /// True when either half of the installation is behind this build: the
    /// script text, or the set of events it is registered for.
    static var isStale: Bool {
        isScriptStale || !isRegistered(in: readSettings())
    }

    /// Brings an existing installation up to this build — script text and
    /// registrations both, via `install()` so the merge exists once.
    ///
    /// Guarded on "registered for at least one event" rather than `isInstalled`,
    /// which requires the complete set: using `isInstalled` would refuse to
    /// repair exactly the incomplete installation that needs it. What it still
    /// will not do is install uninvited.
    @discardableResult
    static func repairIfStale() -> Bool {
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              isRegisteredForAnyEvent(in: readSettings()),
              isStale
        else { return false }
        return install()
    }

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
                    "command": Self.command(for: state)
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
        guard writeSettings(settings),
              !isRegisteredForAnyEvent(in: readSettings())
        else {
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

    /// Whether the script is registered for **all** of `eventStates` — the
    /// question install and staleness ask.
    private static func isRegistered(in settings: [String: Any]?) -> Bool {
        let hooks = settings?["hooks"] as? [String: Any] ?? [:]
        return eventStates.allSatisfy { event, _ in
            (hooks[event] as? [[String: Any]] ?? []).contains {
                commands(in: $0).contains { $0.contains(scriptName) }
            }
        }
    }

    /// Whether the script is registered for **any** event — the question
    /// removal asks. `!isRegistered` is satisfied by a single missing event, so
    /// it would call a partial removal a success and leave live hooks pointing
    /// at a script that is no longer there.
    private static func isRegisteredForAnyEvent(in settings: [String: Any]?) -> Bool {
        let hooks = settings?["hooks"] as? [String: Any] ?? [:]
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains {
                commands(in: $0).contains { $0.contains(scriptName) }
            }
        }
    }

    private static func fail(_ message: String, _ error: Error? = nil) -> Bool {
        lastError = error.map { "\(message): \($0.localizedDescription)" } ?? message
        return false
    }
}
