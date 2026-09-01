import Foundation

/// Installs the Claude Code integration from inside Phantom: a hook
/// script that reports the session state (working / awaiting input /
/// done) into the tab-state file each terminal exports, plus the hook
/// registrations in `~/.claude/settings.json`.
///
/// The settings file is merged, never rewritten: existing hooks and
/// unrelated keys are preserved, and legacy registrations (the
/// ghostty-named script) are migrated on install.
@MainActor
enum ClaudeHooksInstaller {
    static let scriptName = PhantomBuild.fileName("phantom-tab-state.sh")
    /// The name this app wrote before the fork was renamed, matched so an
    /// upgrade's leftover registration can be recognised and removed.
    ///
    /// Empty for anything but the release build. Only the release build ever
    /// wrote it, and a debug build that matched on it would be reaching into
    /// the other build's history to clean up after it.
    static var legacyScriptName: String {
        PhantomBuild.isRelease ? "ghostty-tab-state.sh" : ""
    }

    static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    static var scriptURL: URL {
        claudeDir
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent(scriptName)
    }

    static var settingsURL: URL {
        claudeDir.appendingPathComponent("settings.json")
    }

    /// Hook events and the state each one reports.
    ///
    /// Every name here was checked against the installed binary rather than
    /// against a changelog, and the check is one command — worth re-running
    /// when Claude Code updates, because the list does drift:
    ///
    ///     strings -a "$(command -v claude)" \
    ///       | grep -oE '\["PreToolUse"[^]]{0,600}\]' | head -1
    ///
    /// The binary is minified JavaScript in a Mach-O wrapper and the event
    /// list is a plain array literal, so it comes out whole. As of 2.1.232 it
    /// holds 31 names and contains all ten of these.
    ///
    /// Getting a name wrong is a hard failure, not a silent one: the binary
    /// carries the string *"Not a recognized hook event. Common events:
    /// PreToolUse, PostToolUse, UserPromptSubmit, SessionStart, SessionEnd,
    /// Stop. Check spelling and capitalization."* — so Claude Code rejects an
    /// unknown name rather than ignoring it. That message lists only the six
    /// *common* events and is not the authoritative set; the array literal is.
    ///
    /// This matters more than it looks, because `isRegistered` requires *all*
    /// of these to be present. A name that cannot ever be registered would
    /// make that condition permanently false, which is worse than the bug it
    /// fixes: the settings screen would read "not installed" whatever the user
    /// did, and `repairIfStale` would rewrite the hooks on every launch,
    /// chasing a state it can never reach. So the list has to stay verified,
    /// and the recipe above is how.
    ///
    /// A consequence of the whole set being real and registered: nothing in
    /// `AgentTabState` is decorative. `awaiting`, `failed` and `denied` are all
    /// reachable, and the `notify` marker does get written — they were simply
    /// never registered before.
    ///
    /// `SessionStart` reports no state, and the empty word is the point. It
    /// fires when a session begins, before the user has asked for anything, so
    /// the tab has an id from the moment it opens — which is what keeps a
    /// restore off the directory-scoped fallbacks entirely, and what tells two
    /// tabs in one directory apart, something no on-disk lookup can do. But a
    /// session that has just begun is not *working*, and saying so would spin
    /// an indicator for an agent that has done nothing. An empty first line is
    /// exactly what `TabStateCenter.recordAgentStart` writes and what
    /// `AgentTabRecord` reads back as `state == nil`: identity without
    /// activity.
    ///
    /// `PostCompact` is here to pay for that. `SessionStart` fires again on
    /// resume, on `/clear` and on `/compact`, each of which drops the indicator
    /// back to nothing — right for a cleared session, wrong mid-compaction,
    /// where the agent is working and about to carry on. The alternative was to
    /// have `SessionStart` preserve whatever state word it found, and that is
    /// worse: a stale `working` carried across a `/clear` is wrong in a way
    /// nothing later corrects, where a blink during a compaction heals on the
    /// next tool event. Reporting `working` when compaction finishes removes
    /// even the blink, without teaching the start event to lie.
    static let eventStates: [(event: String, state: String)] = [
        ("SessionStart", ""),
        ("PostCompact", "working"),
        ("UserPromptSubmit", "working"),
        ("PreToolUse", "working"),
        ("PostToolUse", "working"),
        ("PermissionRequest", "awaiting"),
        ("Stop", "done"),
        ("StopFailure", "failed"),
        ("PermissionDenied", "denied"),
        ("Notification", "notify"),
        ("SessionEnd", "ended"),
    ]

    /// The registered command line for one event.
    ///
    /// An empty state passes no argument at all, rather than an empty one. A
    /// trailing space or a literal `''` both depend on how the hook runner
    /// spells out the command — a shell would collapse either to an unset
    /// `$1`, an `execvp` would hand the script two quote characters and call
    /// them a state word. Omitting the argument reads the same both ways, and
    /// the script already treats a missing `$1` as "identity only".
    static func command(for state: String) -> String {
        state.isEmpty ? "'\(scriptURL.path)'" : "'\(scriptURL.path)' \(state)"
    }

    /// Not private, so that a test can run the real script against a real
    /// payload. The id extraction is shell, and the only honest way to check
    /// shell is to execute it.
    ///
    /// A raw literal: the script is dense with backslashes that mean
    /// something to `sed` and to the shell, and nothing to Swift.
    static let scriptBody = #"""
    #!/bin/bash
    # Reports the Claude Code session state to the Phantom sidebar.
    # No-op outside Phantom (env var only exists in Phantom terminals).
    # The atomic write-then-rename is what triggers the directory watch.
    [ -n "$GHOSTTY_TAB_STATE_FILE" ] || exit 0

    # Absent on purpose for SessionStart, which reports identity rather than
    # activity: no argument means an empty first line, which the sidebar reads
    # as "an agent lives here and is doing nothing in particular". Every other
    # event passes a word.
    STATE="$1"

    # Claude Code hands each hook its payload as JSON on stdin, and the
    # session id lives there and nowhere else the hook can see. Read it only
    # when stdin is not a terminal, so running this script by hand cannot sit
    # waiting for input that will never arrive.
    PAYLOAD=""
    if [ ! -t 0 ]; then
      PAYLOAD=$(cat 2>/dev/null)
    fi

    # Refuse anything a shell would read as more than one word, and anything
    # starting with a dash: this value is eventually typed at a prompt after
    # `claude --resume`, where an id spelled like a flag is a flag.
    #
    # A function because both sources of an id have to pass through it. When
    # only the payload was filtered, a corrupt value read back out of the file
    # was copied forward verbatim on every later event, so one bad write stuck
    # to the tab permanently: the file still looked like it held an id, and the
    # resume stayed silently imprecise with nothing able to heal it.
    sanitize_session() {
      case "$1" in
        ""|-*|*[!A-Za-z0-9._-]*) return 0 ;;
        *) printf '%s' "$1" ;;
      esac
    }

    # Deliberately not jq: a hook that needs jq is a hook that silently stops
    # reporting on every machine without it. Lifting one string out of a flat
    # JSON object is within grep and sed's reach, and anything they cannot make
    # sense of degrades to reporting the state alone.
    #
    # The FIRST match, and that is the whole point. A `sed` opening with `.*` is
    # greedy, so it lands on the LAST "session_id" in the payload — and tool
    # events nest one inside `tool_input`/`tool_response`: a subagent call, an
    # MCP tool that hands back a session of its own. That nested id is a
    # perfectly well-formed UUID, so the filter above passes it and nothing
    # downstream objects, and the tab comes back in a conversation it never
    # held. In every payload these CLIs emit the session's own id is a
    # top-level field and so precedes anything nested; taking the first match
    # is what keeps them apart.
    SESSION=$(sanitize_session "$(printf '%s' "$PAYLOAD" | tr -d '\n' \
      | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -n 1 \
      | sed 's/.*"\([^"]*\)"$/\1/')")

    # An event arriving without an id must not erase the one on record. The
    # last write before a quit is the one a restore reads, and nothing says
    # that write will be an event that carried the id.
    if [ -z "$SESSION" ] && [ -f "$GHOSTTY_TAB_STATE_FILE" ]; then
      SESSION=$(sanitize_session "$(sed -n 's/^session=//p' \
        "$GHOSTTY_TAB_STATE_FILE" | head -n 1)")
    fi

    # A temp name private to this invocation. A fixed `.tmp` is one path shared
    # by everything writing this tab — two hooks on parallel tool calls, a
    # second agent in the same terminal, another integration on the same events
    # — and two of them truncating that one file interleaves their bytes. The
    # rename that wins carries the mixture, which is how a `session=` line
    # arrives cut in half; the one that loses renames a file the winner already
    # took, so its error goes to /dev/null rather than into the agent's
    # transcript, and the fragment it left behind is removed.
    #
    # The name still cannot be mistaken for a state file: TabStateCenter only
    # reads entries whose whole name parses as a UUID, and this one does not.
    TMP="$GHOSTTY_TAB_STATE_FILE.$$.tmp"

    # State stays alone on the first line: a Phantom old enough to read only
    # that line keeps reading this file correctly.
    {
      printf '%s\nagent=claude\n' "$STATE"
      if [ -n "$SESSION" ]; then
        printf 'session=%s\n' "$SESSION"
      fi
    } > "$TMP" \
      && mv "$TMP" "$GHOSTTY_TAB_STATE_FILE" 2>/dev/null \
      || rm -f "$TMP"
    exit 0

    """#

    /// Human-readable detail of the last failure, for the settings UI.
    static private(set) var lastError: String?

    private static func fail(_ stage: String, _ error: Error? = nil) -> Bool {
        let detail = error.map { "\(stage): \($0.localizedDescription)" } ?? stage
        lastError = detail
        log("FAIL \(detail)")
        return false
    }

    private static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/phantom-hooks.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Logs each component of the install check, for diagnosis.
    static func logStatus() {
        let scriptExists = FileManager.default.fileExists(atPath: scriptURL.path)
        let readable = (try? Data(contentsOf: settingsURL)) != nil
        log("status script=\(scriptExists) settingsRead=\(readable) registered=\(isRegistered) home=\(FileManager.default.homeDirectoryForCurrentUser.path)")
    }

    /// Whether the hook script is registered for every event this build
    /// reports.
    ///
    /// Checked against the parsed JSON rather than the raw file text: the
    /// serializer's escaping of the path is an implementation detail, and a
    /// substring search would also match the path appearing under some
    /// unrelated key.
    private static var isRegistered: Bool {
        isRegistered(in: readSettings(), scriptName: scriptName)
    }

    /// Whether the script is registered for **all** of `eventStates`.
    ///
    /// Every one, not any one. Accepting a single event is what let an install
    /// performed by an older Phantom — one that knew fewer events — count as
    /// current forever, so the events added since were never registered and the
    /// states behind them became unreachable: no `notify` write, which leaves
    /// `TabStateCenter.handleAttentionMarker` and the whole system-notification
    /// path as code that can never run, and no `failed` or `denied` indicator
    /// either. Nothing else could catch it, because `isScriptStale` compares
    /// the script text and the script text was perfectly current.
    ///
    /// Split out from the property so it can be tested against fixtures — a
    /// full registration, a partial one, no hooks at all, invalid JSON
    /// (`readSettings()` returns nil for that, same as this taking `nil`) —
    /// without touching the real `~/.claude` directory.
    static func isRegistered(in settings: [String: Any]?, scriptName: String) -> Bool {
        guard let hooks = settings?["hooks"] as? [String: Any] else { return false }

        return eventStates.allSatisfy { event, _ in
            registrations(in: hooks[event]).contains { $0.contains(scriptName) }
        }
    }

    /// Whether the script is registered for **any** event.
    ///
    /// The question removal asks, and the one `isRegistered` can no longer
    /// answer: uninstall has to confirm that nothing is left behind, and "not
    /// all nine are present" is satisfied by eight of them still being there.
    /// Two named predicates rather than one with a flag, so that neither call
    /// site can quietly acquire the other's meaning — which is the mistake that
    /// produced the bug above.
    static func isRegisteredForAnyEvent(
        in settings: [String: Any]?, scriptName: String
    ) -> Bool {
        guard let hooks = settings?["hooks"] as? [String: Any] else { return false }

        return hooks.values.contains { value in
            registrations(in: value).contains { $0.contains(scriptName) }
        }
    }

    private static func registrations(in value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).flatMap(commandsIn)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: scriptURL.path) && isRegistered
    }

    /// True when the script file on disk is not the one this build ships.
    ///
    /// `isInstalled` cannot answer this: it asks whether a file is there,
    /// and a stale script is a file that is there. So an install done by an
    /// older Phantom stayed forever — the UI said "installed", offered only
    /// to remove it, and the script kept reporting whatever it knew how to
    /// report. That is how a hook written before session ids existed went on
    /// silently not capturing them, which read as the resume being broken.
    static var isScriptStale: Bool {
        guard let onDisk = try? String(contentsOf: scriptURL, encoding: .utf8)
        else { return false }
        return onDisk != scriptBody
    }

    /// True when anything about the installation is behind this build: the
    /// script text, or the set of events it is registered for.
    ///
    /// The registration half is not decoration. A script can be byte-current
    /// and still be wired to fewer events than the build reports, and that
    /// combination is invisible to a text comparison — see `isRegistered` for
    /// what it costs.
    static var isStale: Bool {
        isScriptStale || !isRegistered
    }

    /// Brings an existing installation up to this build: rewrites the script,
    /// and re-runs the registration merge when the event set is short.
    ///
    /// Safe to do unasked, and better than asking. The script file belongs
    /// entirely to Phantom — generated, never edited — so there is no work of
    /// anyone else's in it. Re-merging the registrations does touch a file that
    /// holds the user's own hooks, which is why it goes through `install()`:
    /// that removes only entries naming this script (or its legacy name) and
    /// appends fresh ones per event, leaving every other hook exactly where it
    /// was. Doing it any other way here would mean a second, divergent copy of
    /// the merge.
    ///
    /// The guard deliberately asks `isRegisteredForAnyEvent` rather than
    /// `isInstalled`. `isInstalled` now requires the *complete* event set, so
    /// using it would have made this refuse to repair precisely the
    /// installation that needs repairing. What it still refuses to do is
    /// install uninvited: no script file, or no registration at all, means the
    /// user never asked for this integration.
    @discardableResult
    static func repairIfStale() -> Bool {
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              isRegisteredForAnyEvent(in: readSettings(), scriptName: scriptName),
              isStale
        else { return false }

        let repaired = install()
        log(repaired ? "repaired stale hook install" : "failed repairing stale hook install")
        return repaired
    }

    @discardableResult
    static func install() -> Bool {
        let fm = FileManager.default

        do {
            try fm.createDirectory(
                at: scriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            return fail("writing hook script", error)
        }

        guard var settings = readSettings() else {
            return fail("settings.json unreadable or not an object")
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for (event, state) in eventStates {
            var entries = hooks[event] as? [[String: Any]] ?? []

            entries.removeAll { entry in
                commandsIn(entry).contains {
                    $0.contains(scriptName)
                        || (!legacyScriptName.isEmpty && $0.contains(legacyScriptName))
                }
            }

            entries.append([
                "hooks": [
                    [
                        "type": "command",
                        "command": Self.command(for: state),
                    ]
                ]
            ])
            hooks[event] = entries
        }

        settings["hooks"] = hooks
        guard writeSettings(settings) else {
            return fail("writing settings.json")
        }

        // Re-read from disk rather than trusting the write: another process
        // owns this file too (Claude Code rewrites it when its own settings
        // change) and can land a stale copy over ours.
        guard isInstalled else {
            return fail("settings.json was written but the hooks are not registered")
        }

        lastError = nil
        log("install ok")
        return true
    }

    @discardableResult
    static func uninstall() -> Bool {
        guard var settings = readSettings() else {
            return fail("settings.json unreadable or not an object")
        }

        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard var entries = value as? [[String: Any]] else { continue }
                entries.removeAll { entry in
                    commandsIn(entry).contains {
                        $0.contains(scriptName)
                        || (!legacyScriptName.isEmpty && $0.contains(legacyScriptName))
                    }
                }
                hooks[event] = entries
            }
            settings["hooks"] = hooks
        }

        try? FileManager.default.removeItem(at: scriptURL)
        guard writeSettings(settings) else {
            return fail("writing settings.json")
        }
        // `isRegisteredForAnyEvent`, because removal has to leave nothing
        // behind: `!isRegistered` is satisfied by one missing event, so it
        // would call a partial removal a success.
        guard !isRegisteredForAnyEvent(in: readSettings(), scriptName: scriptName) else {
            return fail("settings.json was written but the hooks are still registered")
        }
        lastError = nil
        log("uninstall ok")
        return true
    }

    private static func commandsIn(_ entry: [String: Any]) -> [String] {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return [] }
        return inner.compactMap { $0["command"] as? String }
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else {
            return [:]
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeSettings(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        do {
            try data.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
