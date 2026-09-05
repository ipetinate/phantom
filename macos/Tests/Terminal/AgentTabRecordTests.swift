import Foundation
@testable import Ghostty
import Testing

/// The tab-state file is a contract between three shell/JS hook scripts and
/// one Swift decoder, and the two halves ship on different schedules — the
/// scripts live in the user's home directory and are only rewritten when they
/// reinstall the integration. So the parse is pinned from both ends: what an
/// old script wrote must still read, and what the current one writes must
/// survive a round trip.
struct AgentTabRecordTests {
    private let id = "9f8e7d6c-1234-4abc-9def-0123456789ab"

    // MARK: - Backward compatibility

    @Test func aBareStateWordIsStillAValidRecord() {
        let record = AgentTabRecord(fileContents: "working")
        #expect(record.state == .working)
        #expect(record.agent == nil)
        #expect(record.sessionID == nil)
        #expect(!record.carriesIdentity)
    }

    @Test func aBareStateWordSurvivesItsTrailingNewline() {
        #expect(AgentTabRecord(fileContents: "done\n").state == .done)
        #expect(AgentTabRecord(fileContents: "awaiting\r\n").state == .awaiting)
    }

    @Test func aFileWithNoAgentLineResumesAsClaude() {
        #expect(AgentTabRecord.resumeCommand(forStateFileContents: "working")
            == "claude --continue")
    }

    // MARK: - The current format

    @Test func metadataLinesParseIntoAgentAndSession() {
        let record = AgentTabRecord(
            fileContents: "working\nagent=codex\nsession=\(id)\n")
        #expect(record.state == .working)
        #expect(record.agent == .codex)
        #expect(record.sessionID == id)
        #expect(record.carriesIdentity)
    }

    @Test func unknownMetadataKeysAreIgnoredRatherThanFatal() {
        let record = AgentTabRecord(
            fileContents: "done\nagent=claude\nmodel=opus\nsession=\(id)\n")
        #expect(record.agent == .claude)
        #expect(record.sessionID == id)
    }

    @Test func anUnknownAgentNameLeavesTheRecordAgentless() {
        let record = AgentTabRecord(fileContents: "working\nagent=aider\nsession=\(id)")
        #expect(record.agent == nil)
        #expect(record.sessionID == id)
        #expect(record.carriesIdentity)
    }

    @Test func aRecordRoundTripsThroughItsFileForm() {
        let original = AgentTabRecord(stateWord: "awaiting", agent: .opencode, sessionID: id)
        #expect(AgentTabRecord(fileContents: original.fileContents) == original)
    }

    @Test func theStateStaysAloneOnTheFirstLine() {
        let record = AgentTabRecord(stateWord: "working", agent: .claude, sessionID: id)
        let first = record.fileContents.split(separator: "\n").first
        #expect(first == "working")
    }

    /// The state file is a plain file in `~/.cache` and the id it holds is
    /// typed into a live shell. Nothing that could end a command — or start
    /// an argument — may survive the parse.
    ///
    /// `--dangerously-skip-permissions` is in this list because it is spelled
    /// entirely in characters an id may legitimately contain. It is refused
    /// for what its first character makes it: not a session id in the
    /// argument slot, but a second flag.
    @Test(arguments: [
        "abc; rm -rf ~",
        "$(whoami)",
        "`id`",
        "abc def",
        "abc\nrm -rf /",
        "abc'\"",
        "--dangerously-skip-permissions",
        "-r",
        "",
        "   ",
    ])
    func aSessionIdThatCouldMeanSomethingElseIsRefused(_ hostile: String) {
        #expect(AgentTabRecord.sanitized(sessionID: hostile) == nil)
    }

    @Test(arguments: [
        "abc; rm -rf ~",
        "$(whoami)",
        "`id`",
        "abc def",
        "abc'\"",
        "--dangerously-skip-permissions",
        "",
        "   ",
    ])
    func aHostileSessionIdDoesNotSurviveTheFileParse(_ hostile: String) {
        let record = AgentTabRecord(fileContents: "working\nsession=\(hostile)")
        #expect(record.sessionID == nil)
        #expect(AgentTabRecord.resumeCommand(
            forStateFileContents: "working\nagent=claude\nsession=\(hostile)")
            == "claude --continue")
    }

    /// A newline in the value cannot smuggle anything past the parse, because
    /// the parse is line-oriented before it is anything else: what follows
    /// the break is a separate field, and an unrecognized one at that.
    @Test func aNewlineInTheValueEndsTheValue() {
        let record = AgentTabRecord(fileContents: "working\nsession=abc\nrm -rf /\n")
        #expect(record.sessionID == "abc")
        #expect(record.state == .working)
    }

    @Test func anAbsurdlyLongSessionIdIsRefused() {
        #expect(AgentTabRecord.sanitized(sessionID: String(repeating: "a", count: 129)) == nil)
        #expect(AgentTabRecord.sanitized(sessionID: String(repeating: "a", count: 128)) != nil)
    }

    @Test func realSessionIdShapesPassThroughUntouched() {
        #expect(AgentTabRecord.sanitized(sessionID: id) == id)
        #expect(AgentTabRecord.sanitized(sessionID: "ses_2132323b6ffeuRlYHhPcU8DaZ6")
            == "ses_2132323b6ffeuRlYHhPcU8DaZ6")
    }

    // MARK: - What a restored surface runs

    @Test func noStateFileMeansNoAgentWasEverLiveHere() {
        #expect(AgentTabRecord.resumeCommand(forStateFileContents: nil) == nil)
    }

    /// `ended` with nothing to be precise about is left alone: the id-less
    /// fallback resumes whatever is newest in the directory, which for a
    /// session somebody finished is a guess.
    @Test func anEndedSessionWithNoIdIsNotRevived() {
        #expect(AgentTabRecord.resumeCommand(forStateFileContents: "ended") == nil)
        #expect(AgentTabRecord.resumeCommand(
            forStateFileContents: "ended\nagent=claude\n") == nil)
    }

    /// `ended` *with* an id does come back. Quitting kills the agent and the
    /// dying agent's own hook writes `ended`, so at quit time every session
    /// says it — refusing on the word alone is what meant nothing was ever
    /// resumed. The id names the conversation the tab was for.
    @Test func anEndedSessionWithAnIdIsResumedByThatId() {
        #expect(AgentTabRecord.resumeCommand(
            forStateFileContents: "ended\nagent=claude\nsession=\(id)\n")
            == "claude --resume \(id)")
    }

    @Test func eachAgentResumesItsOwnSessionById() {
        #expect(AgentTabRecord.resumeCommand(
            forStateFileContents: "working\nagent=claude\nsession=\(id)")
            == "claude --resume \(id)")
        #expect(AgentTabRecord.resumeCommand(
            forStateFileContents: "working\nagent=codex\nsession=\(id)")
            == "codex resume \(id)")
        #expect(AgentTabRecord.resumeCommand(
            forStateFileContents: "working\nagent=opencode\nsession=\(id)")
            == "opencode --session \(id)")
    }

    /// The pre-session-id behavior, kept as the floor: a tab that never
    /// reported an id still comes back to *something*.
    @Test func anAgentWithNoCapturedIdFallsBackToItsMostRecentConversation() {
        #expect(CodingAgent.claude.resumeCommand(sessionID: nil) == "claude --continue")
        #expect(CodingAgent.codex.resumeCommand(sessionID: nil) == "codex resume --last")
        #expect(CodingAgent.opencode.resumeCommand(sessionID: nil) == "opencode --continue")
    }

    /// What `TabStateCenter.clearDone` leaves behind once a finished tab has
    /// been looked at: no state, so no indicator, but still resumable.
    @Test func aClearedIndicatorStillResumesItsSession() {
        let cleared = AgentTabRecord(stateWord: "", agent: .claude, sessionID: id)
        #expect(cleared.state == nil)
        #expect(cleared.carriesIdentity)
        #expect(AgentTabRecord.resumeCommand(forStateFileContents: cleared.fileContents)
            == "claude --resume \(id)")
    }

    /// The attention marker is not a state, and must not be mistaken for one
    /// — but it still has to survive the parse well enough for
    /// `TabStateCenter` to recognize and consume it.
    @Test func theNotifyMarkerIsAWordButNotAState() {
        let record = AgentTabRecord(fileContents: "notify\nagent=claude\nsession=\(id)")
        #expect(record.stateWord == "notify")
        #expect(record.state == nil)
        #expect(record.sessionID == id)
    }

    // MARK: - An id recovered from the agent's own store

    /// The gap the store fills: an agent was started and nothing was asked of
    /// it, so no hook ever fired and the file names the agent alone.
    @Test func anAgentWithNoIdIsWorthLookingUp() {
        #expect(AgentTabRecord(fileContents: "\nagent=codex\n").needsSessionLookup)
        #expect(AgentTabRecord(fileContents: "working\nagent=claude\n").needsSessionLookup)
        #expect(AgentTabRecord(fileContents: "notify\nagent=opencode\n").needsSessionLookup)
    }

    /// Three reasons not to go looking, each of which the restore path relies
    /// on to avoid touching the filesystem at all.
    @Test func nothingWorthLookingUpIsNotLookedUp() {
        #expect(!AgentTabRecord(
            fileContents: "working\nagent=codex\nsession=\(id)").needsSessionLookup)
        #expect(!AgentTabRecord(fileContents: "working").needsSessionLookup)
        #expect(!AgentTabRecord(fileContents: "ended\nagent=codex\n").needsSessionLookup)
    }

    @Test func aRecoveredIdMakesTheResumePrecise() {
        #expect(AgentTabRecord.resumeCommand(
            forStateFileContents: "\nagent=codex\n", fallbackSessionID: id)
            == "codex resume \(id)")
        #expect(AgentTabRecord.resumeCommand(
            forStateFileContents: "working\nagent=opencode\n", fallbackSessionID: id)
            == "opencode --session \(id)")
    }

    /// The hook's id wins outright: it was reported from inside the
    /// conversation this tab was holding, where the store only knows what was
    /// newest in the directory.
    @Test func theHooksIdBeatsAnythingFoundOnDisk() {
        #expect(AgentTabRecord.resumeCommand(
            forStateFileContents: "working\nagent=codex\nsession=\(id)",
            fallbackSessionID: "01a00090-b0b0-7a52-9698-fa5adf53e115")
            == "codex resume \(id)")
    }

    /// `ended` with no id resumes nothing, and a recovered id does not change
    /// that. The store is keyed by directory, so it inherits the exact
    /// imprecision the rule exists to refuse.
    @Test func anEndedSessionIsNotRevivedByADiskLookupEither() {
        #expect(AgentTabRecord.resumeCommand(
            forStateFileContents: "ended\nagent=codex\n", fallbackSessionID: id) == nil)
    }

    /// A file with no `agent=` line predates the metadata; it still resumes as
    /// Claude's, but on the fallback rather than on an id found by guessing
    /// which agent to go looking for.
    @Test func aFileWithNoAgentLineTakesNoRecoveredId() {
        #expect(AgentTabRecord.resumeCommand(
            forStateFileContents: "working", fallbackSessionID: id) == "claude --continue")
    }

    /// An id off disk becomes a shell argument exactly as one out of the file
    /// does, so it goes through the same sanitizer on the way in.
    @Test(arguments: [
        "abc; rm -rf ~",
        "$(whoami)",
        "--dangerously-skip-permissions",
        "abc def",
        "",
    ])
    func aHostileRecoveredIdIsRefused(_ hostile: String) {
        #expect(AgentTabRecord.resumeCommand(
            forStateFileContents: "\nagent=codex\n", fallbackSessionID: hostile)
            == "codex resume --last")
    }
    // MARK: The agents added in 0.12.0

    /// The binaries, pinned because two of the six are not named after the
    /// agent and a wrong one is a tab that opens a shell error.
    @Test func kimiAndPiLaunchUnderTheirOwnBinaries() {
        #expect(CodingAgent.kimi.launchCommand == "kimi")
        #expect(CodingAgent.pi.launchCommand == "pi")
    }

    @Test func theirNamesAreTheOnesTheirVendorsUse() {
        #expect(CodingAgent.kimi.displayName == "Kimi Code")
        #expect(CodingAgent.pi.displayName == "Pi")
    }

    /// `--session` and not `--resume` for both, and that is the whole point of
    /// pinning it. Kimi's `--resume` is a hidden alias for `--session`, and
    /// Pi's opens a picker for a human to choose from — a picker is the wrong
    /// thing for a tab restoring itself, which already knows which
    /// conversation it wants.
    @Test func resumingNamesTheSessionRatherThanOpeningAPicker() {
        #expect(CodingAgent.kimi.resumeCommand(sessionID: "abc") == "kimi --session abc")
        #expect(CodingAgent.pi.resumeCommand(sessionID: "abc") == "pi --session abc")
    }

    /// With no id there is nothing to name, and both document `--continue` as
    /// picking up the most recent conversation.
    @Test func withNoSessionIDBothContinueInstead() {
        #expect(CodingAgent.kimi.resumeCommand(sessionID: nil) == "kimi --continue")
        #expect(CodingAgent.pi.resumeCommand(sessionID: nil) == "pi --continue")
        #expect(CodingAgent.kimi.resumeCommand(sessionID: "") == "kimi --continue")
    }

    /// Every agent has to answer both questions, which is the reason they are
    /// answered in one type. A case added without a launch command is a button
    /// that does nothing.
    @Test func everyAgentHasABinaryAndAName() {
        for agent in CodingAgent.allCases {
            #expect(!agent.launchCommand.isEmpty)
            #expect(!agent.displayName.isEmpty)
            #expect(!agent.resumeCommand(sessionID: nil).isEmpty)
        }
    }
}

/// Runs the hook script Phantom actually installs.
///
/// The id extraction is shell, and the only honest way to check shell is to
/// execute it — a Swift reimplementation of the same `sed` would prove
/// nothing about the string that lands in the user's `~/.claude/hooks`.
@MainActor
struct ClaudeHookScriptTests {
    private let id = "9f8e7d6c-1234-4abc-9def-0123456789ab"

    private func withInstalledScript(
        _ body: (_ script: URL, _ stateFile: URL) throws -> Void
    ) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent(TabStateScript.fileName)
        try TabStateScript.body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        try body(script, dir.appendingPathComponent("state"))
    }

    private func arguments(state: String) -> [String] {
        TabStateScript.arguments(
            agent: AgentRegistry.claude.id,
            state: state,
            options: TabStateScript.options(of: AgentRegistry.claude))
    }

    /// Invokes the script the way a registered hook does — state as `$1`, the
    /// descriptor's options after it, payload on stdin — and returns whatever
    /// it left in the state file.
    @discardableResult
    private func fire(
        _ script: URL,
        state: String,
        payload: String?,
        stateFile: URL
    ) throws -> String? {
        let process = Process()
        process.executableURL = script
        process.arguments = arguments(state: state)
        var environment = ProcessInfo.processInfo.environment
        environment["GHOSTTY_TAB_STATE_FILE"] = stateFile.path
        process.environment = environment

        if let payload {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(Data(payload.utf8))
            try stdin.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        return try? String(contentsOf: stateFile, encoding: .utf8)
    }

    @Test func liftsTheSessionIdOutOfTheJSONOnStdin() throws {
        try withInstalledScript { script, stateFile in
            let written = try fire(
                script,
                state: "working",
                payload: #"{"session_id":"\#(id)","transcript_path":"/tmp/t.jsonl","cwd":"/tmp"}"#,
                stateFile: stateFile)

            let record = AgentTabRecord(fileContents: try #require(written))
            #expect(record.state == .working)
            #expect(record.agent == .claude)
            #expect(record.sessionID == id)
        }
    }

    @Test func toleratesAPrettyPrintedPayload() throws {
        try withInstalledScript { script, stateFile in
            let written = try fire(script, state: "awaiting", payload: """
            {
              "session_id": "\(id)",
              "hook_event_name": "PermissionRequest"
            }
            """, stateFile: stateFile)

            #expect(AgentTabRecord(fileContents: try #require(written)).sessionID == id)
        }
    }

    /// The write immediately before a quit is the one a restore reads, and
    /// nothing promises it carried an id.
    @Test func anEventWithoutAnIdKeepsTheOneAlreadyRecorded() throws {
        try withInstalledScript { script, stateFile in
            try fire(
                script,
                state: "working",
                payload: #"{"session_id":"\#(id)"}"#,
                stateFile: stateFile)

            let written = try fire(
                script,
                state: "done",
                payload: #"{"hook_event_name":"Stop"}"#,
                stateFile: stateFile)

            let record = AgentTabRecord(fileContents: try #require(written))
            #expect(record.state == .done)
            #expect(record.sessionID == id)
        }
    }

    /// A hook invoked with no payload at all — the shape every pre-stdin
    /// caller had — must still report, and must not hang waiting on stdin.
    @Test func reportsStateAloneWhenThereIsNoPayload() throws {
        try withInstalledScript { script, stateFile in
            let written = try fire(script, state: "working", payload: nil, stateFile: stateFile)
            let record = AgentTabRecord(fileContents: try #require(written))
            #expect(record.state == .working)
            #expect(record.agent == .claude)
            #expect(record.sessionID == nil)
        }
    }

    @Test func refusesASessionIdCarryingShellSyntax() throws {
        try withInstalledScript { script, stateFile in
            let written = try fire(
                script,
                state: "working",
                payload: #"{"session_id":"abc; rm -rf ~"}"#,
                stateFile: stateFile)

            let record = AgentTabRecord(fileContents: try #require(written))
            #expect(record.state == .working)
            #expect(record.sessionID == nil)
            #expect(!(written ?? "").contains("rm -rf"))
        }
    }

    @Test func refusesASessionIdShapedLikeAFlag() throws {
        try withInstalledScript { script, stateFile in
            let written = try fire(
                script,
                state: "working",
                payload: #"{"session_id":"--dangerously-skip-permissions"}"#,
                stateFile: stateFile)

            #expect(!(written ?? "").contains("dangerously"))
            #expect(AgentTabRecord(fileContents: try #require(written)).sessionID == nil)
        }
    }

    @Test func doesNothingOutsidePhantom() throws {
        try withInstalledScript { script, stateFile in
            let process = Process()
            process.executableURL = script
            process.arguments = arguments(state: "working")
            process.environment = ["PATH": "/usr/bin:/bin"]
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            #expect(process.terminationStatus == 0)
            #expect(!FileManager.default.fileExists(atPath: stateFile.path))
        }
    }

    /// End to end, in the order the pieces actually run: the hook writes, the
    /// decoder reads, and the restored surface gets a command naming *this*
    /// conversation rather than the newest one in the directory.
    @Test func whatTheHookWritesIsWhatARestoredSurfaceResumes() throws {
        try withInstalledScript { script, stateFile in
            let written = try fire(
                script,
                state: "working",
                payload: #"{"session_id":"\#(id)"}"#,
                stateFile: stateFile)

            #expect(AgentTabRecord.resumeCommand(forStateFileContents: written)
                == "claude --resume \(id)")
        }
    }
}

/// What can be checked about the two integrations whose CLIs are not
/// installed here.
///
/// Not much, and deliberately not more: these assert that the scripts parse
/// and that their *shell* does what it should, never that Codex or OpenCode
/// send the fields being read. Whether the ids are ever populated is unknown
/// until someone runs this with those agents installed.
@MainActor
struct UninstallableAgentHookTests {
    /// The Codex script's payload keys are guesses; its shell is not. A
    /// script that fails to parse would silently stop reporting state at all,
    /// which is a regression independent of whether the ids ever arrive.
    @Test func theCodexScriptIsValidShell() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("codex-tab-state.sh")
        try TabStateScript.body.write(to: script, atomically: true, encoding: .utf8)

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/bash")
        check.arguments = ["-n", script.path]
        try check.run()
        check.waitUntilExit()
        #expect(check.terminationStatus == 0)
    }

    /// And the same script, run: it reports state, names its agent, and — if
    /// Codex does turn out to send one of the keys it looks for — carries the
    /// id through. The payload here is Claude's shape, so this proves the
    /// plumbing, not the guess.
    @Test func theCodexScriptReportsStateAndNamesItsAgent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("codex-tab-state.sh")
        try TabStateScript.body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        let stateFile = dir.appendingPathComponent("state")

        let process = Process()
        process.executableURL = script
        process.arguments = TabStateScript.arguments(
            agent: AgentRegistry.codex.id,
            state: "working",
            options: TabStateScript.options(of: AgentRegistry.codex))
        var environment = ProcessInfo.processInfo.environment
        environment["GHOSTTY_TAB_STATE_FILE"] = stateFile.path
        process.environment = environment
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(#"{"conversation_id":"codex-abc-123"}"#.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let record = AgentTabRecord(
            fileContents: try #require(try? String(contentsOf: stateFile, encoding: .utf8)))
        #expect(record.state == .working)
        #expect(record.agent == .codex)
        #expect(record.sessionID == "codex-abc-123")
        #expect(AgentTabRecord.resumeCommand(forStateFileContents: record.fileContents)
            == "codex resume codex-abc-123")
    }

    /// Node is how OpenCode loads this plugin, so node is what gets to say
    /// whether it parses. Disabled rather than failed where node is absent —
    /// the app never needs it, only this check does.
    @Test(.enabled(if: nodeIsAvailable))
    func theOpenCodePluginParsesAsAModule() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-opencode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plugin = dir.appendingPathComponent("phantom-integration.mjs")
        try #require(PluginFileInstaller.body(of: AgentRegistry.opencode))
            .write(to: plugin, atomically: true, encoding: .utf8)

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        check.arguments = ["node", "--check", plugin.path]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try check.run()
        check.waitUntilExit()

        #expect(check.terminationStatus == 0)
    }

    /// OpenCode's answer to a session-start hook is the `session.created`
    /// event, which fires before the user has asked for anything. Driving the
    /// real plugin under node is the only way to check it: the id extraction is
    /// a chain of optional property reads across two SDK generations, and a
    /// Swift restatement of that chain would prove nothing about the JS that
    /// OpenCode loads.
    @Test(.enabled(if: nodeIsAvailable), arguments: [
        // The `sessionID` shape, and the `info.id` shape. The plugin reads both
        // because the two live SDK generations disagree, and which one is in
        // play is not Phantom's to decide.
        #"{"sessionID":"ses_abc123","info":{"id":"ses_abc123","directory":"/tmp"}}"#,
        #"{"info":{"id":"ses_abc123","directory":"/tmp"}}"#,
    ])
    func aCreatedSessionRecordsIdentityWithoutAnIndicator(_ properties: String) throws {
        let written = try #require(try driveOpenCodePlugin(events: [
            #"{"type":"session.created","properties":\#(properties)}"#
        ]))

        let record = AgentTabRecord(fileContents: written)
        #expect(record.stateWord.isEmpty)
        #expect(record.state == nil, "a created session must show no indicator")
        #expect(record.agent == .opencode)
        #expect(record.sessionID == "ses_abc123")
    }

    /// A subagent runs in a child session, and resuming by its id opens that
    /// thread rather than the conversation the tab holds. `parentID` is what
    /// separates them.
    @Test(.enabled(if: nodeIsAvailable))
    func aSubagentSessionDoesNotBecomeTheTabsIdentity() throws {
        let written = try #require(try driveOpenCodePlugin(events: [
            #"{"type":"session.created","properties":{"sessionID":"ses_parent","info":{"id":"ses_parent","directory":"/tmp"}}}"#,
            #"{"type":"session.created","properties":{"sessionID":"ses_child","info":{"id":"ses_child","parentID":"ses_parent","directory":"/tmp"}}}"#,
        ]))

        #expect(AgentTabRecord(fileContents: written).sessionID == "ses_parent")
    }

    @Test(.enabled(if: nodeIsAvailable))
    func aSubagentStartingFirstLeavesTheTabWithoutAnId() throws {
        let written = try #require(try driveOpenCodePlugin(events: [
            #"{"type":"session.created","properties":{"sessionID":"ses_child","info":{"id":"ses_child","parentID":"ses_parent","directory":"/tmp"}}}"#,
        ]))

        let record = AgentTabRecord(fileContents: written)
        #expect(record.sessionID == nil)
        #expect(record.agent == .opencode)
        #expect(record.needsSessionLookup, "the disk lookup is what finishes this record")
    }

    /// Loads the generated plugin under node, feeds it the given events in
    /// order, and returns whatever it left in the state file.
    private func driveOpenCodePlugin(events: [String]) throws -> String? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-opencode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plugin = dir.appendingPathComponent("phantom-integration.mjs")
        try #require(PluginFileInstaller.body(of: AgentRegistry.opencode))
            .write(to: plugin, atomically: true, encoding: .utf8)

        let stateFile = dir.appendingPathComponent("state")
        // The plugin serializes its writes through a promise chain, so the
        // driver has to let that chain drain before reading.
        let driver = dir.appendingPathComponent("drive.mjs")
        try """
        import { PhantomPlugin } from "./phantom-integration.mjs";
        const plugin = await PhantomPlugin();
        for (const event of [\(events.joined(separator: ","))]) {
          await plugin.event({ event });
        }
        await new Promise((resolve) => setTimeout(resolve, 200));
        """.write(to: driver, atomically: true, encoding: .utf8)

        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        run.arguments = ["node", driver.path]
        var environment = ProcessInfo.processInfo.environment
        environment["GHOSTTY_TAB_STATE_FILE"] = stateFile.path
        run.environment = environment
        run.standardOutput = FileHandle.nullDevice
        run.standardError = FileHandle.nullDevice
        try run.run()
        run.waitUntilExit()
        #expect(run.terminationStatus == 0)

        return try? String(contentsOf: stateFile, encoding: .utf8)
    }
}

/// Whether `node` can be reached from here. Xcode hands tests the launching
/// shell's environment, and a version manager's node lives on a PATH that a
/// GUI-launched Xcode may not have.
private let nodeIsAvailable: Bool = {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    probe.arguments = ["node", "--version"]
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    do { try probe.run() } catch { return false }
    probe.waitUntilExit()
    return probe.terminationStatus == 0
}()
