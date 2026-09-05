import Foundation

/// Installs Antigravity lifecycle hooks without replacing hooks owned by the
/// user or another integration. Each hook writes the same per-terminal state
/// file the sidebar's other three agents write.
///
/// Two things about Antigravity's hook system differ from Claude Code's and
/// Codex's, and both shape everything below.
///
/// **The file is a map of named hooks, not a `hooks` key.** Claude Code and
/// Codex both nest their registrations under a top-level `"hooks"` object
/// keyed by event. Antigravity's `hooks.json` is keyed by a *name the author
/// chooses*, and the events live one level inside that:
///
///     { "my-linter-hook": { "PostToolUse": [ … ] } }
///
/// So Phantom owns exactly one top-level key, `phantom-tab-state`, and the
/// merge replaces that key and touches nothing else. This is a stronger
/// guarantee than the other two installers can offer — they have to filter
/// individual entries out of event arrays they share with everybody — and it
/// is the one place Antigravity's design is easier to integrate with.
///
/// **A hook is expected to answer on stdout.** The other two write a file and
/// exit. Antigravity reads a JSON object back from every hook, and the shape
/// depends on the event, so the script is told which event invoked it and
/// prints accordingly. It prints that answer *before* it does anything else,
/// so no failure in the state write can cost the agent its reply.
///
/// Sources, since none of this was measured against a running `agy` — no such
/// binary was installed on the machine this was written on:
/// <https://antigravity.google/docs/hooks/> for the schema, the five event
/// names, the stdin fields and the per-event stdout contract;
/// <https://antigravity.google/docs/cli/reference/> for `agy` and
/// `--conversation` / `--continue`; and Mete Atamel's
/// <https://atamel.dev/posts/2026/07-16_where_agy_hooks/> for the two paths
/// `agy` actually reads and for a hook script that was run rather than
/// documented. Where the docs and that post disagree, the post wins.
@MainActor
enum AntigravityHooksInstaller {
    static let scriptName = PhantomBuild.fileName("phantom-tab-state.sh")

    /// The one top-level key Phantom owns in `hooks.json`. Everything the
    /// merge does is scoped to it.
    static let hookName = "phantom-tab-state"

    /// `~/.gemini/config`, which is where `agy` reads a user-level
    /// `hooks.json` from.
    ///
    /// Not `~/.gemini/antigravity-cli`, which is the CLI's *settings*
    /// directory and holds `settings.json`. The two are documented a page
    /// apart and are easy to conflate; hooks land in `config`. The workspace
    /// half of the pair, `.agents/hooks.json`, is deliberately left alone —
    /// it belongs to a repository, would follow the repository into version
    /// control, and would have to be installed once per project.
    static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
    }

    static var scriptURL: URL { configDir.appendingPathComponent(scriptName) }
    static var settingsURL: URL { configDir.appendingPathComponent("hooks.json") }

    /// Hook events and the state each one reports.
    ///
    /// Two, where Claude Code gets eleven, and the three that are missing are
    /// missing on purpose rather than for lack of an event to use.
    ///
    /// `PreToolUse` is refused. It is the only event Antigravity offers that
    /// could report a permission prompt, and its stdout contract makes that
    /// unaffordable: `decision` is *required*, and the values are `allow`,
    /// `deny`, `ask`, `force_ask` and `deny_unless_prior_grant`. A reporting
    /// hook has no opinion to express, so the only value it could send is
    /// `allow` — which is not a neutral answer, it is a standing approval of
    /// every tool call the agent ever makes. Trading the user's permission
    /// prompts for an indicator light is not a trade Phantom gets to make on
    /// their behalf.
    ///
    /// `PostToolUse` is dropped because it would change nothing. It reports
    /// `working`, and `PreInvocation` has already reported `working` for this
    /// turn; nothing writes `done` until `Stop`. So the indicator reads the
    /// same with it and without it, and the cost of including it is a
    /// `matcher` field whose grammar is undocumented — the schema's only
    /// example matches the literal tool name `run_command`, and whether an
    /// omitted or wildcard matcher means "every tool" is exactly the kind of
    /// guess that registers a hook which never fires.
    ///
    /// `PostInvocation` is dropped because it would actively lie. It fires
    /// after *each* model call, and an agent turn is many calls with tool runs
    /// between them, so reporting `done` there would blink the tab to finished
    /// several times in the middle of work that is still going.
    ///
    /// What the two that remain give up is `awaiting`, and with it `failed`,
    /// `denied`, `notify` and `ended` — none of which Antigravity has an event
    /// for that this is willing to use. A tab running Antigravity therefore
    /// shows working and done and nothing else, and `endedByUser` is never
    /// marked for it, so a tab whose session the reader quit still tries to
    /// resume on the next launch. Both are honest gaps, not bugs to chase.
    ///
    /// `PreInvocation` doubles as the identity event the other installers get
    /// from `SessionStart`, and it is worse at it: it fires before the model
    /// is called, which cannot happen until the reader has asked for
    /// something. So a tab where `agy` is up but unprompted holds no id. The
    /// fallback for that is better here than anywhere else, though —
    /// `agy --continue` is documented as loading the last conversation *for
    /// this workspace*, which is the scoping the other agents needed
    /// `AgentSessionStore` to reconstruct.
    static let eventStates: [(event: String, state: String)] = [
        ("PreInvocation", "working"),
        ("Stop", "done"),
    ]

    /// The registered command line for one event.
    ///
    /// Both the state and the event name are bare words, and that is the
    /// point — see `ClaudeHooksInstaller.command` for why a quoted argument in
    /// a registered command line is a hazard. The event name has to reach the
    /// script because Antigravity's stdout contract is per-event, and passing
    /// it beats parsing `hookEventName` back out of the payload: a word the
    /// installer already knows cannot fail to parse.
    static func command(for state: String, event: String) -> String {
        command(for: state, event: event, scriptPath: scriptURL.path)
    }

    static func command(for state: String, event: String, scriptPath: String) -> String {
        "'\(scriptPath)' \(state) \(event)"
    }

    /// Not private, so a test can run the real script against a real payload.
    /// The reply and the id extraction are both shell, and the only honest way
    /// to check shell is to execute it.
    static let scriptBody = #"""
    #!/bin/bash
    # Reports Antigravity session state to the Phantom sidebar.
    STATE="$1"
    EVENT="$2"

    # Antigravity expects a JSON object back from every hook, and the shape is
    # per-event: Stop takes a `decision`, everything else takes an empty
    # object. Printed first, before any of the work below, so that no missing
    # state file and no failed write can cost the agent its reply — a hook
    # that answers nothing is a hook whose runner has to guess.
    #
    # `stop` rather than `continue`: `continue` is the documented value that
    # *prevents* the agent from stopping, which is the opposite of what a
    # reporting hook wants. `stop` is what a working script in the wild sends
    # to mean "stop normally".
    case "$EVENT" in
      Stop) printf '{"decision":"stop"}\n' ;;
      *) printf '{}\n' ;;
    esac

    # No-op outside Phantom: the env var only exists in Phantom terminals. The
    # reply above has already been sent, so `agy` is unaffected either way.
    [ -n "$GHOSTTY_TAB_STATE_FILE" ] || exit 0

    PAYLOAD=""
    if [ ! -t 0 ]; then
      PAYLOAD=$(cat 2>/dev/null)
    fi
    FLAT=$(printf '%s' "$PAYLOAD" | tr -d '\n')

    # This value is eventually typed at a prompt after `agy --conversation`,
    # so anything a shell would read as more than one word is refused, and so
    # is a leading dash, which would arrive there as a flag.
    #
    # A function because every source of an id goes through it: each candidate
    # key, and the value carried forward out of the file. Filtering only the
    # payload leaves a corrupt carried value to be copied forward on every
    # later event, so one bad write sticks to the tab permanently.
    sanitize_session() {
      case "$1" in
        ""|-*|*[!A-Za-z0-9._-]*) return 0 ;;
        *) printf '%s' "$1" ;;
      esac
    }

    # `conversationId` is the documented field, and Antigravity calls it a
    # conversation where the others call it a session. The remaining spellings
    # cost a `grep` each and are there because the payload is Antigravity's to
    # change, not Phantom's.
    #
    # The FIRST match per key, not the last. A `sed` opening with `.*` is
    # greedy and lands on the LAST occurrence — and a tool payload nests
    # arguments that can carry an id of their own, which is a well-formed
    # value that passes the filter and resumes a conversation the tab never
    # held. The real id is top-level and so precedes anything nested.
    #
    # Filtering inside the loop rather than after it, so a key that matches
    # something unusable does not shadow the keys still untried.
    SESSION=""
    for KEY in conversationId conversation_id sessionId session_id; do
      [ -n "$SESSION" ] && break
      SESSION=$(sanitize_session "$(printf '%s' "$FLAT" \
        | grep -o "\"$KEY\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -n 1 \
        | sed 's/.*"\([^"]*\)"$/\1/')")
    done

    # An event arriving without an id must not erase the one on record: the
    # last write before a quit is the one a restore reads, and nothing says
    # that write will be the event that carried the id.
    if [ -z "$SESSION" ] && [ -f "$GHOSTTY_TAB_STATE_FILE" ]; then
      SESSION=$(sanitize_session "$(sed -n 's/^session=//p' \
        "$GHOSTTY_TAB_STATE_FILE" | head -n 1)")
    fi

    # A temp name private to this invocation. A fixed `.tmp` is one path
    # shared by everything writing this tab — a second agent in the same
    # terminal, another integration on the same events — and two of them
    # truncating that one file interleaves their bytes. The rename that wins
    # carries the mixture, which is how a `session=` line arrives cut in half.
    #
    # The name still cannot be mistaken for a state file: TabStateCenter reads
    # only entries whose whole name parses as a UUID, and this one does not.
    TMP="$GHOSTTY_TAB_STATE_FILE.$$.tmp"

    # State stays alone on the first line: a Phantom old enough to read only
    # that line keeps reading this file correctly.
    #
    # `2>/dev/null` comes BEFORE `> "$TMP"`, and the order is the whole point.
    # Bash applies redirections left to right, so a stderr redirect written
    # after the one that fails is installed too late to catch its own
    # complaint: opening an unwritable path prints "No such file or directory"
    # to whatever stderr was at that moment. Silencing stderr first is what
    # keeps that message out of the reader's transcript, and `agy` is a hook
    # runner that can put it there. Measured, not assumed — a test fires this
    # script at a path inside a directory that does not exist and asserts
    # stderr stays empty.
    {
      printf '%s\nagent=antigravity\n' "$STATE"
      if [ -n "$SESSION" ]; then
        printf 'session=%s\n' "$SESSION"
      fi
    } 2>/dev/null > "$TMP" \
      && mv "$TMP" "$GHOSTTY_TAB_STATE_FILE" 2>/dev/null \
      || rm -f "$TMP" 2>/dev/null
    exit 0
    """#

    static private(set) var lastError: String?

    /// True when the installed script file is not the one this build ships.
    /// See `ClaudeHooksInstaller.isScriptStale` for why `isInstalled` cannot
    /// answer it.
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
    /// Guarded on "registered for at least one event" rather than
    /// `isInstalled`, which requires the complete set: using `isInstalled`
    /// would refuse to repair exactly the incomplete installation that needs
    /// it. What it still will not do is install uninvited.
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
                at: configDir, withIntermediateDirectories: true
            )
            try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
            )
        } catch {
            return fail("writing the Antigravity hook script", error)
        }

        guard var settings = readSettings() else {
            return fail("hooks.json is unreadable or isn't a JSON object")
        }

        settings[hookName] = Self.registration
        guard writeSettings(settings), isInstalled else {
            return fail("Antigravity hooks were written but could not be verified")
        }
        lastError = nil
        return true
    }

    /// The whole value of Phantom's one top-level key, rebuilt from
    /// `eventStates` rather than merged into.
    ///
    /// Replacing it outright is safe here in a way it would not be in the
    /// other two installers: this key is Phantom's alone by construction, so
    /// there is nothing of anyone else's inside it to preserve. It also means
    /// an event this build has dropped leaves no registration behind pointing
    /// at a script that no longer reports it.
    ///
    /// Both events take their handlers directly under the event key, with no
    /// `matcher` and no wrapping group. That is the documented shape for
    /// `PreInvocation`, `PostInvocation` and `Stop` — the grouped
    /// `{ matcher, hooks }` form belongs to the tool events, which
    /// `eventStates` deliberately does not register.
    static var registration: [String: Any] {
        registration(scriptPath: scriptURL.path)
    }

    static func registration(scriptPath: String) -> [String: Any] {
        var events: [String: Any] = [:]
        for (event, state) in eventStates {
            events[event] = [
                [
                    "type": "command",
                    "command": Self.command(for: state, event: event, scriptPath: scriptPath),
                ]
            ]
        }
        return events
    }

    @discardableResult
    static func uninstall() -> Bool {
        guard var settings = readSettings() else {
            return fail("hooks.json is unreadable or isn't a JSON object")
        }
        settings.removeValue(forKey: hookName)
        try? FileManager.default.removeItem(at: scriptURL)
        guard writeSettings(settings),
              !isRegisteredForAnyEvent(in: readSettings())
        else {
            return fail("removing the Antigravity hooks")
        }
        lastError = nil
        return true
    }

    /// Reads `hooks.json`, telling "there is nothing here yet" apart from
    /// "there is something here this doesn't understand" — the same
    /// distinction `CodexHooksInstaller.readSettings(at:)` draws, and for the
    /// same reason.
    ///
    /// An empty dictionary means the file is absent or empty, which the
    /// installer may safely create. Nil means a file exists that isn't a JSON
    /// object — hand-edited, half-written, a top-level array — and the
    /// installer must leave it alone. Collapsing the two is what turns one
    /// malformed byte into the atomic replacement of every hook the user had.
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

    /// Every command registered under Phantom's own key for `event`.
    ///
    /// Scoped to that key rather than searching the whole file, because a
    /// command naming this script under somebody *else's* hook name is not
    /// this installer's registration: `install` would not update it and
    /// `uninstall` would not remove it, so counting it as installed would
    /// describe a state the buttons cannot act on.
    static func commands(in settings: [String: Any]?, event: String) -> [String] {
        guard let definition = settings?[hookName] as? [String: Any],
              let handlers = definition[event] as? [[String: Any]]
        else { return [] }
        return handlers.compactMap { $0["command"] as? String }
    }

    /// Whether the script is registered for **all** of `eventStates` — the
    /// question install and staleness ask.
    static func isRegistered(in settings: [String: Any]?) -> Bool {
        eventStates.allSatisfy { event, _ in
            commands(in: settings, event: event).contains { $0.contains(scriptName) }
        }
    }

    /// Whether the script is registered for **any** event — the question
    /// removal asks. `!isRegistered` is satisfied by a single missing event,
    /// so it would call a partial removal a success and leave a live hook
    /// pointing at a script that is no longer there.
    static func isRegisteredForAnyEvent(in settings: [String: Any]?) -> Bool {
        guard let definition = settings?[hookName] as? [String: Any] else {
            return false
        }
        return definition.keys.contains { event in
            commands(in: settings, event: event).contains { $0.contains(scriptName) }
        }
    }

    private static func fail(_ message: String, _ error: Error? = nil) -> Bool {
        lastError = error.map { "\(message): \($0.localizedDescription)" } ?? message
        return false
    }
}
