import Foundation
@testable import Ghostty
import Testing

/// The Antigravity integration, whose two risks are both new to this repo.
///
/// **The script has to answer.** Claude Code's and Codex's hooks write a file
/// and exit; Antigravity reads a JSON object back from every hook, and the
/// shape depends on the event. A hook that stays silent is a hook whose runner
/// has to guess, so the reply is asserted directly — and asserted on the paths
/// where it would be easiest to lose it: outside Phantom, and with an
/// unwritable state file.
///
/// **The id is a conversation id.** Antigravity calls it a conversation where
/// the others call it a session, and its spelling comes first in the keys the
/// descriptor registers.
///
/// The file half — the owned key in `hooks.json` — is covered by
/// `JSONHooksInstallerTests`, against the same descriptor.
@MainActor
struct AntigravityHookScriptTests {
    private let real = "fe5e4f94-d3e0-4af7-b877-42073d603aff"
    private let nested = "deadbeef-0000-4000-8000-000000000000"

    private var events: [HooksIntegration.Event] {
        AgentRegistry.antigravity.hooks?.hookEvents ?? []
    }

    private func reply(for event: String) -> String? {
        events.first { $0.name == event }?.reply
    }

    // MARK: - Harness

    private struct Installed {
        let directory: URL
        let script: URL
        let stateFile: URL
    }

    private struct Fired {
        let contents: String?
        let standardOutput: String
        let standardError: String
    }

    private func withInstalledScript(_ body: (Installed) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-agy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("phantom-tab-state.sh")
        try TabStateScript.body
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        try body(Installed(
            directory: directory,
            script: script,
            stateFile: directory.appendingPathComponent("state")))
    }

    /// Invoked exactly as a registration invokes it: state as `$1`, then the
    /// descriptor's options and the reply this event owes, the payload on
    /// stdin, `GHOSTTY_TAB_STATE_FILE` in the environment unless `inPhantom`
    /// says otherwise.
    @discardableResult
    private func fire(
        _ installed: Installed,
        state: String,
        event: String,
        payload: String?,
        inPhantom: Bool = true
    ) throws -> Fired {
        let process = Process()
        process.executableURL = installed.script
        process.arguments = TabStateScript.arguments(
            agent: AgentRegistry.antigravity.id,
            state: state,
            options: TabStateScript.options(of: AgentRegistry.antigravity),
            reply: reply(for: event))

        var environment = ProcessInfo.processInfo.environment
        if inPhantom {
            environment["GHOSTTY_TAB_STATE_FILE"] = installed.stateFile.path
        } else {
            environment.removeValue(forKey: "GHOSTTY_TAB_STATE_FILE")
        }
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
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

        let captured = output.fileHandleForReading.readDataToEndOfFile()
        let complaints = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        return Fired(
            contents: try? String(contentsOf: installed.stateFile, encoding: .utf8),
            standardOutput: Self.text(captured),
            standardError: Self.text(complaints))
    }

    private static func text(_ data: Data) -> String {
        data.isEmpty ? "" : (String(bytes: data, encoding: .utf8) ?? "<undecodable>")
    }

    private func record(_ fired: Fired) throws -> AgentTabRecord {
        AgentTabRecord(fileContents: try #require(fired.contents))
    }

    /// The reply, parsed. Asserting on the decoded object rather than on the
    /// text means the script may lay its JSON out however it likes and still
    /// only has to be *valid*, which is the actual contract.
    private func reply(_ fired: Fired) throws -> [String: Any] {
        let data = Data(fired.standardOutput.utf8)
        let object = try? JSONSerialization.jsonObject(with: data)
        return try #require(
            object as? [String: Any],
            "not a JSON object: \(fired.standardOutput.debugDescription)")
    }

    // MARK: - The reply Antigravity reads back

    @Test func aStopEventRepliesWithADecision() throws {
        try withInstalledScript { installed in
            let fired = try fire(
                installed, state: "done", event: "Stop", payload: "{}")

            #expect(try reply(fired)["decision"] as? String == "stop")
            #expect(fired.standardError.isEmpty)
        }
    }

    /// Everything that is not `Stop` replies with an empty object, which is the
    /// documented shape for `PreInvocation`. The reply is the registration's:
    /// each event's command line carries the JSON its runner reads back.
    @Test func aPreInvocationRepliesWithAnEmptyObject() throws {
        try withInstalledScript { installed in
            let fired = try fire(
                installed, state: "working", event: "PreInvocation", payload: "{}")

            #expect(try reply(fired).isEmpty)
            #expect(fired.standardError.isEmpty)
        }
    }

    @Test func everyRegisteredEventCarriesAReply() {
        for event in events {
            #expect(event.reply != nil, Comment(rawValue: event.name))
        }
        #expect(reply(for: "Stop") == #"{"decision":"stop"}"#)
        #expect(reply(for: "PreInvocation") == "{}")
        #expect(reply(for: "SomeFutureEvent") == nil)
    }

    /// The reply is printed before the state work, so nothing about the state
    /// file can cost the agent its answer. Outside Phantom the script exits
    /// immediately — and that early exit is exactly where a reply appended at
    /// the end would be skipped.
    @Test func theReplySurvivesRunningOutsidePhantom() throws {
        try withInstalledScript { installed in
            let fired = try fire(
                installed, state: "done", event: "Stop", payload: "{}",
                inPhantom: false)

            #expect(try reply(fired)["decision"] as? String == "stop")
            #expect(fired.contents == nil, "no state file should have been written")
            #expect(fired.standardError.isEmpty)
        }
    }

    /// The other way the state write can fail: the path is set but unwritable.
    /// The reply still has to come out, and nothing may reach stderr — `agy`
    /// can surface a hook's complaints to the reader.
    @Test func theReplySurvivesAnUnwritableStateFile() throws {
        try withInstalledScript { installed in
            let blocked = Installed(
                directory: installed.directory,
                script: installed.script,
                stateFile: installed.directory
                    .appendingPathComponent("no-such-directory/state"))

            let fired = try fire(
                blocked, state: "working", event: "PreInvocation", payload: "{}")

            #expect(try reply(fired).isEmpty)
            #expect(fired.standardError.isEmpty)
        }
    }

    // MARK: - The conversation id

    @Test func theConversationIdIsRecordedAsTheSessionId() throws {
        try withInstalledScript { installed in
            let fired = try fire(
                installed, state: "working", event: "PreInvocation",
                payload: #"{"conversationId":"\#(real)","modelName":"gemini"}"#)

            let parsed = try record(fired)
            #expect(parsed.sessionID == real)
            #expect(parsed.agent == .antigravity)
            #expect(parsed.state == .working)
        }
    }

    /// A `sed` opening with `.*` is greedy and lands on the last match, and a
    /// tool payload nests arguments that can carry an id of their own. That
    /// nested value is a well-formed UUID, so no filter downstream objects and
    /// the tab comes back in a conversation it never held.
    @Test func aNestedIdDoesNotWinOverTheRealOne() throws {
        try withInstalledScript { installed in
            let fired = try fire(
                installed, state: "working", event: "PreInvocation",
                payload: """
                {"conversationId":"\(real)",\
                "toolCall":{"args":{"conversationId":"\(nested)"}},\
                "stepIdx":3}
                """)

            #expect(try record(fired).sessionID == real)
        }
    }

    /// One filter over both sources of an id. Filtering only the payload leaves
    /// a corrupt carried value to be copied forward on every later event, so a
    /// single bad write sticks to the tab permanently.
    @Test func aCorruptCarriedIdIsDroppedRatherThanPropagated() throws {
        try withInstalledScript { installed in
            try "done\nagent=antigravity\nsession=bad id; rm -rf /\n"
                .write(to: installed.stateFile, atomically: true, encoding: .utf8)

            let parsed = try record(try fire(
                installed, state: "working", event: "PreInvocation", payload: "{}"))

            #expect(parsed.sessionID == nil)
            #expect(parsed.state == .working)
            #expect(parsed.agent == .antigravity)
        }
    }

    /// An event carrying no id must not erase the one on record: the last write
    /// before a quit is the one a restore reads, and nothing says that write
    /// will be the event that carried the id.
    @Test func aGoodCarriedIdSurvivesAnEventThatMentionsNoId() throws {
        try withInstalledScript { installed in
            try "working\nagent=antigravity\nsession=\(real)\n"
                .write(to: installed.stateFile, atomically: true, encoding: .utf8)

            let parsed = try record(try fire(
                installed, state: "done", event: "Stop", payload: "{}"))

            #expect(parsed.sessionID == real)
            #expect(parsed.state == .done)
        }
    }

    /// Filtering happens inside the key loop, so a key matching something
    /// unusable does not shadow the keys still untried.
    @Test func theNextKeyIsTriedWhenTheFirstYieldsSomethingUnusable() throws {
        try withInstalledScript { installed in
            let fired = try fire(
                installed, state: "working", event: "PreInvocation",
                payload: #"{"conversationId":"--nope","sessionId":"\#(real)"}"#)

            #expect(try record(fired).sessionID == real)
        }
    }

    // MARK: - The registered command line

    /// The state and the options are bare words; only the JSON reply is
    /// quoted, because it holds quotes of its own. A quoted argument in a
    /// registered command line reads differently depending on whether a shell
    /// is in the way.
    @Test func theRegisteredCommandPassesBareWordsAndAQuotedReply() throws {
        let engine = try #require(JSONHooksInstaller(descriptor: AgentRegistry.antigravity))
        let path = engine.scriptURL.path
        let working = engine.command(for: .init("PreInvocation", "working", reply: "{}"))
        let done = engine.command(for: .init("Stop", "done", reply: #"{"decision":"stop"}"#))

        #expect(working.hasPrefix("'\(path)' working --agent antigravity --session-key conversationId"))
        #expect(working.hasSuffix(" --reply '{}'"))
        #expect(done.hasSuffix(#" --reply '{"decision":"stop"}'"#))
        #expect(!working.contains("''"))
        #expect(!working.hasSuffix(" "))
    }

    // MARK: - The spellings that reach a shell prompt

    /// The resume commands, which are typed at a live prompt. Antigravity's are
    /// documented rather than measured — no `agy` was installed when this was
    /// written — so the shape is pinned here to make a wrong guess fail loudly
    /// rather than silently open the wrong conversation.
    @Test func theResumeSpellingsAreAntigravitys() {
        let agent = CodingAgent.antigravity

        #expect(agent.launchCommand == "agy")
        #expect(agent.resumeCommand(sessionID: real) == "agy --conversation \(real)")
        #expect(agent.resumeCommand(sessionID: nil) == "agy --continue")
        #expect(agent.resumeCommand(sessionID: "") == "agy --continue")
    }

    /// An id shaped like a flag must not reach `agy --conversation` as one.
    @Test func aFlagShapedIdFallsBackToContinue() {
        let written = AgentTabRecord(
            stateWord: "working",
            agent: .antigravity,
            sessionID: "--conversation-that-is-a-flag")

        #expect(written.sessionID == nil)
        #expect(
            AgentTabRecord.resumeCommand(forStateFileContents: written.fileContents)
                == "agy --continue")
    }

    /// The round trip through the state file, which is what a restore reads.
    @Test func anAntigravityRecordRestoresItsOwnConversation() {
        let written = AgentTabRecord(
            stateWord: "working", agent: .antigravity, sessionID: real)

        #expect(
            AgentTabRecord.resumeCommand(forStateFileContents: written.fileContents)
                == "agy --conversation \(real)")
    }

    /// Antigravity has no session-end event, so `ended` is never written for it
    /// and `AgentSessionStore` has no store to read. Both gaps land on the same
    /// fallback, and `agy --continue` is documented as workspace-scoped — which
    /// is the scoping the store exists to reconstruct for the other three.
    @Test func thereIsNoStoreToFallBackOn() {
        #expect(
            AgentSessionStore.default.mostRecentSessionID(
                agent: .antigravity,
                workingDirectory: FileManager.default.currentDirectoryPath) == nil)
    }
}
