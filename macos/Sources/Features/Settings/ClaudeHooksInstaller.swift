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
    static let scriptName = TabStateScript.fileName
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
    /// nothing later corrects. Reporting `working` when compaction finishes
    /// bounds the damage without teaching the start event to lie.
    ///
    /// `PreCompact` is the other half, and it is the half the reader sees. An
    /// automatic compaction begins with the API refusing an oversized turn,
    /// which Claude Code reports through `StopFailure` — so the tab turns red
    /// and then compacts for minutes behind that red triangle. `PreCompact`
    /// replaces it with `compacting` at the moment the work starts, and the
    /// script keeps that word across the `SessionStart` in the middle by
    /// reading the `source` the payload carries. Between them the mark says
    /// "busy" for the whole operation, which no pair of events registered here
    /// could say on its own.
    static let eventStates: [(event: String, state: String)] = [
        ("SessionStart", ""),
        ("PreCompact", "compacting"),
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
        command(for: state, scriptPath: scriptURL.path)
    }

    static func command(for state: String, scriptPath: String) -> String {
        TabStateScript.commandLine(
            scriptPath: scriptPath,
            arguments: TabStateScript.arguments(
                agent: AgentRegistry.claude.id,
                state: state,
                options: TabStateScript.options(of: AgentRegistry.claude)))
    }

    static let scriptBody = TabStateScript.body

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

        guard let before = readSettings() else {
            return fail("settings.json unreadable or not an object")
        }
        let settings = registered(
            into: before, scriptPath: scriptURL.path, legacyScriptName: legacyScriptName)
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

    static func registered(
        into settings: [String: Any],
        scriptPath: String,
        legacyScriptName: String
    ) -> [String: Any] {
        let scriptName = (scriptPath as NSString).lastPathComponent
        var settings = settings
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
                        "command": Self.command(for: state, scriptPath: scriptPath),
                    ]
                ]
            ])
            hooks[event] = entries
        }

        settings["hooks"] = hooks
        return settings
    }

    static func removed(
        from settings: [String: Any],
        scriptName: String,
        legacyScriptName: String
    ) -> [String: Any] {
        var settings = settings
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
        return settings
    }

    @discardableResult
    static func uninstall() -> Bool {
        guard let before = readSettings() else {
            return fail("settings.json unreadable or not an object")
        }
        let settings = removed(
            from: before, scriptName: scriptName, legacyScriptName: legacyScriptName)

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
