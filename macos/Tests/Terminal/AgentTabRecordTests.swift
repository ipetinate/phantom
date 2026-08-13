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

    @Test func anEndedSessionIsNotRevived() {
        #expect(AgentTabRecord.resumeCommand(forStateFileContents: "ended") == nil)
        #expect(AgentTabRecord.resumeCommand(
            forStateFileContents: "ended\nagent=claude\nsession=\(id)\n") == nil)
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

        let script = dir.appendingPathComponent(ClaudeHooksInstaller.scriptName)
        try ClaudeHooksInstaller.scriptBody.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        try body(script, dir.appendingPathComponent("state"))
    }

    /// Invokes the script the way a registered hook does — state as `$1`,
    /// payload on stdin — and returns whatever it left in the state file.
    @discardableResult
    private func fire(
        _ script: URL,
        state: String,
        payload: String?,
        stateFile: URL
    ) throws -> String? {
        let process = Process()
        process.executableURL = script
        process.arguments = [state]
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
            process.arguments = ["working"]
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
        try CodexHooksInstaller.scriptBody.write(to: script, atomically: true, encoding: .utf8)

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
        try CodexHooksInstaller.scriptBody.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        let stateFile = dir.appendingPathComponent("state")

        let process = Process()
        process.executableURL = script
        process.arguments = ["working"]
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
        try OpenCodeHooksInstaller.pluginBody.write(to: plugin, atomically: true, encoding: .utf8)

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        check.arguments = ["node", "--check", plugin.path]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try check.run()
        check.waitUntilExit()

        #expect(check.terminationStatus == 0)
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
