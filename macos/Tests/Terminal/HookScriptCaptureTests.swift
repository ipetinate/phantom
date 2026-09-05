import Foundation
@testable import Ghostty
import Testing

/// Runs the hook scripts Phantom generates against payloads shaped like the
/// ones that broke them.
///
/// Every defect these cover shipped, and every one of them was invisible to a
/// test that did not execute the script: the id extraction is `sed` and `grep`,
/// the atomicity is `mv`, and the filtering is a `case` — a Swift
/// reimplementation of any of the three would prove nothing about the text that
/// lands in the user's `~/.claude/hooks`. So the script body is written to a
/// temp directory and invoked exactly as a registered hook invokes it: state as
/// `$1`, the descriptor's options after it, JSON payload on stdin,
/// `GHOSTTY_TAB_STATE_FILE` in the environment.
@MainActor
struct HookScriptCaptureTests {
    /// The id a session actually has, and one belonging to something else that
    /// the payload also happens to mention.
    private let real = "fe5e4f94-d3e0-4af7-b877-42073d603aff"
    private let nested = "deadbeef-0000-4000-8000-000000000000"

    /// Which agent's registration is under test. One script serves both; what
    /// differs is the arguments each descriptor registers it with.
    enum Script: String, Sendable, CaseIterable {
        case claude
        case codex

        var agent: CodingAgent {
            switch self {
            case .claude: return .claude
            case .codex: return .codex
            }
        }

        func arguments(state: String?) -> [String] {
            TabStateScript.arguments(
                agent: rawValue,
                state: state ?? "",
                options: TabStateScript.options(of: agent.descriptor))
        }
    }

    // MARK: - Harness

    private struct Installed {
        let kind: Script
        let directory: URL
        let script: URL
        let stateFile: URL
    }

    private func withInstalledScripts(
        _ body: (_ install: (Script) throws -> Installed) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stateFile = directory.appendingPathComponent("state")
        try body { script in
            let url = directory.appendingPathComponent("\(script.rawValue)-tab-state.sh")
            try TabStateScript.body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
            return Installed(kind: script, directory: directory, script: url, stateFile: stateFile)
        }
    }

    /// The result of one hook invocation: what it left on disk, and whether it
    /// said anything on the way. Both matter — Claude Code can surface a hook's
    /// stderr into the transcript, so a hook that works but complains is still
    /// a hook that shows the user an error.
    private struct Fired {
        let contents: String?
        let standardError: String
    }

    /// `state: nil` invokes the script with **no argument**, which is how the
    /// stateless `SessionStart` registration invokes it.
    @discardableResult
    private func fire(
        _ installed: Installed,
        state: String?,
        payload: String?
    ) throws -> Fired {
        let process = Process()
        process.executableURL = installed.script
        process.arguments = installed.kind.arguments(state: state)
        var environment = ProcessInfo.processInfo.environment
        environment["GHOSTTY_TAB_STATE_FILE"] = installed.stateFile.path
        process.environment = environment

        let errors = Pipe()
        process.standardError = errors

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

        let captured = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        return Fired(
            contents: try? String(contentsOf: installed.stateFile, encoding: .utf8),
            standardError: Self.text(captured)
        )
    }

    /// Undecodable output is reported as a placeholder rather than as nothing,
    /// so that a hook which said something unreadable still fails the
    /// "said nothing" assertion.
    private static func text(_ data: Data) -> String {
        data.isEmpty ? "" : (String(bytes: data, encoding: .utf8) ?? "<undecodable>")
    }

    private func record(_ fired: Fired) throws -> AgentTabRecord {
        AgentTabRecord(fileContents: try #require(fired.contents))
    }

    // MARK: - A SessionStart in the middle of a compaction

    /// The event that reports identity rather than activity is also the event
    /// that fires halfway through a compaction, and blanking the mark there is
    /// what left a three-minute operation looking like nothing was happening.
    /// The script reads the `source` the payload carries and keeps the word.
    @Test func aCompactionSessionStartHoldsTheCompactingMark() throws {
        try withInstalledScripts { install in
            let installed = try install(.claude)
            let fired = try fire(
                installed,
                state: nil,
                payload: """
                    {"session_id":"\(real)","source":"compact",\
                    "hook_event_name":"SessionStart","cwd":"/tmp"}
                    """)
            let parsed = try record(fired)
            #expect(parsed.state == .compacting)
            #expect(parsed.sessionID == real)
            #expect(parsed.agent == .claude)
            #expect(fired.standardError.isEmpty)
        }
    }

    /// And every other source still reports identity without activity, which
    /// is the whole reason `SessionStart` passes no word: a session that has
    /// just begun must not spin an indicator.
    @Test(arguments: ["startup", "resume", "clear"])
    func anOrdinarySessionStartReportsNoActivity(_ source: String) throws {
        try withInstalledScripts { install in
            let installed = try install(.claude)
            let fired = try fire(
                installed,
                state: nil,
                payload: """
                    {"session_id":"\(real)","source":"\(source)",\
                    "hook_event_name":"SessionStart","cwd":"/tmp"}
                    """)
            let parsed = try record(fired)
            #expect(parsed.state == nil)
            #expect(parsed.sessionID == real)
            #expect(fired.standardError.isEmpty)
        }
    }

    // MARK: - The id in the payload is not the only id in the payload

    /// A tool event carries the session's own id at the top level *and*
    /// whatever id the tool itself reported, nested. A `sed` opening with `.*`
    /// is greedy, so it took the last one — a subagent's, or an MCP server's.
    /// The result is a well-formed UUID that no filter downstream can object
    /// to, and a tab that comes back in a conversation it never held. This is
    /// the "it's resuming the wrong session" report.
    @Test(arguments: Script.allCases)
    func aNestedSessionIdDoesNotWinOverTheRealOne(_ script: Script) throws {
        try withInstalledScripts { install in
            let installed = try install(script)
            let fired = try fire(installed, state: "working", payload: """
            {"session_id":"\(real)","tool_response":{"session_id":"\(nested)"},"n":1}
            """)

            let parsed = try record(fired)
            #expect(parsed.sessionID == real)
            #expect(parsed.agent == script.agent)
            #expect(fired.standardError.isEmpty)
        }
    }

    @Test(arguments: Script.allCases)
    func severalNestedSessionIdsStillLose(_ script: Script) throws {
        try withInstalledScripts { install in
            let fired = try fire(try install(script), state: "working", payload: """
            {"hook_event_name":"PostToolUse","session_id":"\(real)",\
            "tool_input":{"session_id":"\(nested)","prompt":"go"},\
            "tool_response":{"session_id":"\(nested)","nested":{"session_id":"\(nested)"}}}
            """)

            #expect(try record(fired).sessionID == real)
        }
    }

    /// Codex tries five spellings in turn, so a nested match under a key it
    /// checks first must not beat the real one either.
    @Test func codexPrefersItsOwnSessionIdOverANestedConversationId() throws {
        try withInstalledScripts { install in
            let fired = try fire(try install(.codex), state: "working", payload: """
            {"session_id":"\(real)","tool_response":{"conversation_id":"\(nested)"}}
            """)

            #expect(try record(fired).sessionID == real)
        }
    }

    // MARK: - One filter, over both sources of an id

    /// A corrupt value read back out of the state file used to be copied
    /// forward verbatim, because only the payload was filtered. That made a
    /// single bad write permanent: the file still looked like it held an id, so
    /// nothing tried to replace it, and the resume stayed quietly imprecise
    /// with nothing able to heal it.
    @Test(arguments: Script.allCases)
    func aCorruptCarriedIdIsDroppedRatherThanPropagated(_ script: Script) throws {
        try withInstalledScripts { install in
            let installed = try install(script)
            try "done\nagent=\(script.rawValue)\nsession=bad id; rm -rf /\n"
                .write(to: installed.stateFile, atomically: true, encoding: .utf8)

            let parsed = try record(try fire(installed, state: "working", payload: "{}"))
            #expect(parsed.sessionID == nil)
            #expect(parsed.state == .working)
            #expect(parsed.agent == script.agent)
        }
    }

    /// Filtering both sources must not cost the fallback *between* them: an
    /// event whose own id is unusable still has to fall back to the good id on
    /// record, rather than blanking the tab's identity on its way past.
    @Test(arguments: Script.allCases)
    func anUnusablePayloadIdFallsBackToTheGoodCarriedOne(_ script: Script) throws {
        try withInstalledScripts { install in
            let installed = try install(script)
            try "done\nagent=\(script.rawValue)\nsession=\(real)\n"
                .write(to: installed.stateFile, atomically: true, encoding: .utf8)

            let fired = try fire(
                installed, state: "working", payload: #"{"session_id":"not an id"}"#)
            #expect(try record(fired).sessionID == real)
        }
    }

    @Test(arguments: Script.allCases)
    func aGoodCarriedIdSurvivesAnEventThatMentionsNoId(_ script: Script) throws {
        try withInstalledScripts { install in
            let installed = try install(script)
            try "working\nagent=\(script.rawValue)\nsession=\(real)\n"
                .write(to: installed.stateFile, atomically: true, encoding: .utf8)

            let fired = try fire(installed, state: "ended", payload: "{}")
            let parsed = try record(fired)
            #expect(parsed.sessionID == real)
            #expect(parsed.state == .ended)
        }
    }

    /// Codex filters inside its key loop, so a key that matches something
    /// unusable does not shadow the keys it has not tried yet.
    @Test func codexTriesTheNextKeyWhenTheFirstYieldsSomethingUnusable() throws {
        try withInstalledScripts { install in
            let fired = try fire(try install(.codex), state: "working", payload: """
            {"session_id":"--nope","thread_id":"\(real)"}
            """)

            #expect(try record(fired).sessionID == real)
        }
    }

    // MARK: - Two hooks, one tab

    /// Concurrent writers used to share one `.tmp` path, so two of them
    /// truncating that single file interleaved their bytes: the rename that won
    /// carried the mixture, which is how a `session=` line comes back cut in
    /// half. The loser then renamed a file the winner had already moved and
    /// said so on stderr, which Claude Code can surface to the user.
    ///
    /// Who collides in practice: two Claude hooks on parallel tool calls, a
    /// second agent in the same terminal, and any other integration registered
    /// on the same events.
    ///
    /// The assertion is that every outcome is one writer's *complete* record.
    /// Which writer wins is a race and is not the point — a mixture of the two
    /// is.
    @Test func concurrentWritersLeaveOneCompleteRecordAndNoFragments() throws {
        let claudeID = real
        let codexID = "01a00081-7b2c-7550-9f51-29231263da7c"

        try withInstalledScripts { install in
            let claude = try install(.claude)
            let codex = try install(.codex)

            let acceptable: Set<String> = [
                "working\nagent=claude\nsession=\(claudeID)\n",
                "done\nagent=codex\nsession=\(codexID)\n",
            ]

            for round in 1...20 {
                let first = try started(claude, state: "working", id: claudeID)
                let second = try started(codex, state: "done", id: codexID)
                first.process.waitUntilExit()
                second.process.waitUntilExit()

                let contents = try #require(
                    try? String(contentsOf: claude.stateFile, encoding: .utf8))
                #expect(
                    acceptable.contains(contents),
                    "round \(round) produced a mixture: \(contents.debugDescription)")

                for pipe in [first.errors, second.errors] {
                    let text = Self.text(pipe.fileHandleForReading.readDataToEndOfFile())
                    #expect(text.isEmpty, "round \(round) wrote to stderr: \(text)")
                }
            }

            let leftovers = (try? FileManager.default.contentsOfDirectory(
                at: claude.directory, includingPropertiesForKeys: nil
            ))?.filter { TabStateCenter.isWriteFragment($0) } ?? []
            #expect(leftovers.isEmpty, "write fragments survived: \(leftovers)")
        }
    }

    /// Starts a hook without waiting for it, so two can be in flight at once.
    private func started(
        _ installed: Installed, state: String, id: String
    ) throws -> (process: Process, errors: Pipe) {
        let process = Process()
        process.executableURL = installed.script
        process.arguments = installed.kind.arguments(state: state)
        var environment = ProcessInfo.processInfo.environment
        environment["GHOSTTY_TAB_STATE_FILE"] = installed.stateFile.path
        process.environment = environment

        let errors = Pipe()
        process.standardError = errors
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(#"{"session_id":"\#(id)"}"#.utf8))
        try stdin.fileHandleForWriting.close()
        return (process, errors)
    }

    // MARK: - The session-start registration

    /// The event that makes the whole thing precise: an id from the moment the
    /// tab opens, so no restore ever reaches a directory-scoped fallback, and
    /// two tabs in one directory are told apart — which no on-disk lookup can
    /// do, because nothing on disk distinguishes them.
    @Test func bothInstallersRegisterASessionStartThatReportsNoState() {
        let claude = ClaudeHooksInstaller.eventStates
        let codex = CodexHooksInstaller.eventStates

        #expect(claude.contains { $0.event == "SessionStart" && $0.state.isEmpty })
        #expect(codex.contains { $0.event == "SessionStart" && $0.state.isEmpty })

        // Exactly one event may be stateless. Anything else reporting an empty
        // word would silently erase a live indicator.
        #expect(claude.filter { $0.state.isEmpty }.count == 1)
        #expect(codex.filter { $0.state.isEmpty }.count == 1)
    }

    /// PascalCase is what `hooks.json` takes. The snake_case spellings are
    /// Codex's internal normalization and appear only as bookkeeping keys under
    /// `[hooks.state]` in `config.toml`; writing those would register nothing.
    @Test func codexEventNamesArePascalCase() {
        for (event, _) in CodexHooksInstaller.eventStates {
            #expect(!event.contains("_"), "\(event) is not the spelling hooks.json takes")
            #expect(event.first?.isUppercase == true, "\(event) is not PascalCase")
        }
    }

    /// A stateless event passes no state word at all rather than an empty one,
    /// so the registered line cannot carry a literal `''` whose meaning depends
    /// on whether a shell is in the way. The descriptor's options follow the
    /// script either way, and the agent is always named.
    @Test func aStatelessEventRegistersWithNoStateWord() {
        let path = ClaudeHooksInstaller.scriptURL.path
        let stateless = ClaudeHooksInstaller.command(for: "")

        #expect(!stateless.hasSuffix(" "))
        #expect(!stateless.contains("''"))
        #expect(stateless.hasPrefix("'\(path)' --agent claude"))
        #expect(ClaudeHooksInstaller.command(for: "done").hasPrefix("'\(path)' done --agent claude"))
        #expect(CodexHooksInstaller.command(for: "")
            .hasPrefix("'\(CodexHooksInstaller.scriptURL.path)' --agent codex"))
        #expect(!CodexHooksInstaller.command(for: "").hasSuffix(" "))
    }

    /// Invoked the way that registration invokes it — no argument — the script
    /// has to leave a record with identity and no state. Nothing had ever
    /// exercised the empty-state path: every hook passed a word, and the only
    /// other writer of an empty one is `TabStateCenter.recordAgentStart`, on
    /// the Swift side.
    @Test(arguments: Script.allCases)
    func aStartEventRecordsIdentityWithoutAnIndicator(_ script: Script) throws {
        try withInstalledScripts { install in
            let fired = try fire(
                try install(script), state: nil,
                payload: #"{"session_id":"\#(real)","source":"startup"}"#)

            let parsed = try record(fired)
            #expect(parsed.stateWord.isEmpty)
            #expect(parsed.state == nil, "a starting session must show no indicator")
            #expect(parsed.agent == script.agent)
            #expect(parsed.sessionID == real)
            #expect(parsed.carriesIdentity)
            #expect(fired.standardError.isEmpty)
        }
    }

    /// A start payload with no id still has to leave the tab knowably an
    /// agent's — the same record the app writes at tab creation, which the disk
    /// lookup can then finish.
    @Test(arguments: Script.allCases)
    func aStartEventWithNoIdStillNamesTheAgent(_ script: Script) throws {
        try withInstalledScripts { install in
            let parsed = try record(
                try fire(try install(script), state: nil, payload: "{}"))
            #expect(parsed.agent == script.agent)
            #expect(parsed.sessionID == nil)
            #expect(parsed.needsSessionLookup)
        }
    }

    /// `SessionStart` fires again on resume and on `/clear`, and must not undo
    /// the identity it established. The indicator does drop back to nothing,
    /// which is correct for `/clear` and briefly wrong during a `/compact` —
    /// the next tool event restores it.
    @Test(arguments: Script.allCases)
    func aRepeatedStartEventKeepsTheIdItAlreadyRecorded(_ script: Script) throws {
        try withInstalledScripts { install in
            let installed = try install(script)
            try fire(installed, state: nil,
                     payload: #"{"session_id":"\#(real)","source":"startup"}"#)
            try fire(installed, state: "working", payload: "{}")

            let parsed = try record(
                try fire(installed, state: nil, payload: #"{"source":"resume"}"#))
            #expect(parsed.sessionID == real)
            #expect(parsed.state == nil)
        }
    }

    /// A fragment is named so that the directory watch cannot mistake it for a
    /// record — which is what lets it be swept on its own schedule.
    @Test func aWriteFragmentIsNotMistakenForAStateFile() {
        let surface = UUID()
        let state = TabStateCenter.stateFileURL(for: surface)
        #expect(!TabStateCenter.isWriteFragment(state))
        #expect(TabStateCenter.isWriteFragment(
            state.deletingLastPathComponent()
                .appendingPathComponent("\(surface.uuidString).4821.tmp")))
        #expect(UUID(uuidString: "\(surface.uuidString).4821.tmp") == nil)
    }
}
