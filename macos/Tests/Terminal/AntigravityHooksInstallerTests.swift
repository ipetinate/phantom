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
/// **The file is a map of named hooks.** Antigravity's `hooks.json` is keyed by
/// a name the author picks, with the events nested inside, where the other two
/// nest everything under a top-level `"hooks"`. Reading Phantom's own key out
/// of a file full of somebody else's is therefore a different operation from
/// the one the other installers perform, and gets its own fixtures.
///
/// The write half of `install()` and `uninstall()` is not exercised, for the
/// reason `CodexHooksInstallerTests` gives: both resolve their own path from
/// `configDir`, so testing them would mean either a test-only seam on a
/// production singleton or writing into the developer's real `~/.gemini`
/// during a test run.
@MainActor
struct AntigravityHooksInstallerTests {
    private let real = "fe5e4f94-d3e0-4af7-b877-42073d603aff"
    private let nested = "deadbeef-0000-4000-8000-000000000000"

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
            reply: AntigravityHooksInstaller.reply(for: event))

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
        for (event, _) in AntigravityHooksInstaller.eventStates {
            #expect(AntigravityHooksInstaller.reply(for: event) != nil, event)
        }
        #expect(AntigravityHooksInstaller.reply(for: "Stop") == #"{"decision":"stop"}"#)
        #expect(AntigravityHooksInstaller.reply(for: "PreInvocation") == "{}")
        #expect(AntigravityHooksInstaller.reply(for: "SomeFutureEvent") == nil)
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

    /// Antigravity calls it a conversation where the others call it a session,
    /// and `conversationId` is the documented spelling.
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
                installed, state: "working", event: "PostToolUse",
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

    // MARK: - What is registered, and what is refused

    /// `PreToolUse` is the refusal that matters. Its stdout contract makes
    /// `decision` mandatory, and the only value a reporting hook could send is
    /// `allow` — a standing approval of every tool call the agent ever makes.
    /// Registering it would trade the reader's permission prompts for an
    /// indicator light.
    @Test func noToolPermissionEventIsRegistered() {
        let events = AntigravityHooksInstaller.eventStates.map(\.event)

        #expect(!events.contains("PreToolUse"))

        // `PostInvocation` fires after each model call, and an agent turn is
        // many calls with tool runs between them. Reporting `done` there would
        // blink the tab to finished in the middle of work still going.
        #expect(!events.contains("PostInvocation"))
    }

    /// Every registered event is one Antigravity documents. A name it does not
    /// recognize registers nothing, and nothing is what the sidebar would then
    /// show — with no error anywhere to explain it.
    @Test func everyRegisteredEventIsARealAntigravityEvent() {
        let known: Set<String> = [
            "PreToolUse", "PostToolUse", "PreInvocation", "PostInvocation", "Stop",
        ]

        for (event, _) in AntigravityHooksInstaller.eventStates {
            #expect(known.contains(event), "\(event) is not an Antigravity hook event")
        }

        #expect(!AntigravityHooksInstaller.eventStates.isEmpty)
    }

    /// Only events that take their handlers *directly* under the event key are
    /// registered. The grouped `{ matcher, hooks }` form belongs to the tool
    /// events, whose matcher grammar is undocumented — the schema's one example
    /// matches a literal tool name, so a wildcard may well register a hook that
    /// never fires.
    @Test func theRegistrationUsesTheUngroupedHandlerShape() throws {
        let registration = AntigravityHooksInstaller.registration

        #expect(registration.count == AntigravityHooksInstaller.eventStates.count)

        for (event, _) in AntigravityHooksInstaller.eventStates {
            let handlers = try #require(
                registration[event] as? [[String: Any]],
                "\(event) is not a list of handlers")

            #expect(handlers.count == 1)
            #expect(handlers.first?["type"] as? String == "command")
            #expect(handlers.first?["matcher"] == nil)
            #expect(handlers.first?["hooks"] == nil)
        }
    }

    /// The state and the options are bare words; only the JSON reply is
    /// quoted, because it holds quotes of its own. A quoted argument in a
    /// registered command line reads differently depending on whether a shell
    /// is in the way — see `ClaudeHooksInstaller.command`.
    @Test func theRegisteredCommandPassesBareWordsAndAQuotedReply() {
        let path = AntigravityHooksInstaller.scriptURL.path
        let working = AntigravityHooksInstaller.command(for: "working", event: "PreInvocation")
        let done = AntigravityHooksInstaller.command(for: "done", event: "Stop")

        #expect(working.hasPrefix("'\(path)' working --agent antigravity --session-key conversationId"))
        #expect(working.hasSuffix(" --reply '{}'"))
        #expect(done.hasSuffix(#" --reply '{"decision":"stop"}'"#))
        #expect(!working.contains("''"))
        #expect(!working.hasSuffix(" "))
    }

    /// The registration has to survive its own serializer. `install()` writes
    /// it through `JSONSerialization`, and a value that cannot be encoded fails
    /// there rather than here.
    @Test func theRegistrationSerializesToJSON() throws {
        let payload = [AntigravityHooksInstaller.hookName: AntigravityHooksInstaller.registration]

        #expect(JSONSerialization.isValidJSONObject(payload))

        let data = try JSONSerialization.data(withJSONObject: payload)
        let round = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(round?[AntigravityHooksInstaller.hookName] != nil)
    }

    // MARK: - Reading somebody else's hooks.json

    private func settings(_ json: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// The whole registration, read back as installed.
    @Test func aCompleteRegistrationReadsAsInstalled() throws {
        let file = try settings(#"{"phantom-tab-state":\#(registrationJSON())}"#)

        #expect(AntigravityHooksInstaller.isRegistered(in: file))
        #expect(AntigravityHooksInstaller.isRegisteredForAnyEvent(in: file))
    }

    /// A registration short of one event is not installed — but is still
    /// *something*, which is what lets `repairIfStale` finish it and what stops
    /// `uninstall` from calling a partial removal a success.
    /// The command names the script, and the script's name carries the build
    /// — `phantom-debug-tab-state.sh` in a second build — so the fixture asks
    /// the installer for it rather than spelling it. Spelled out, this pinned
    /// one build and failed in the other.
    @Test func aPartialRegistrationIsIncompleteButPresent() throws {
        let script = AntigravityHooksInstaller.scriptName
        let file = try settings("""
        {"\(AntigravityHooksInstaller.hookName)":{"Stop":[{"type":"command",\
        "command":"'/x/\(script)' done Stop"}]}}
        """)

        #expect(!AntigravityHooksInstaller.isRegistered(in: file))
        #expect(AntigravityHooksInstaller.isRegisteredForAnyEvent(in: file))
    }

    /// Somebody else's hooks are not Phantom's, however many there are and
    /// whatever they run. Reading them as installed would have the settings
    /// screen offer to remove a hook it does not own.
    @Test func anotherAuthorsHooksAreNotPhantoms() throws {
        let file = try settings("""
        {"my-linter-hook":{"PostToolUse":[{"matcher":"run_command",\
        "hooks":[{"type":"command","command":"./scripts/lint.sh"}]}]},\
        "safety-gate":{"enabled":false,"PreToolUse":[{"matcher":"run_command",\
        "hooks":[{"command":"./scripts/safety-check.sh"}]}]}}
        """)

        #expect(!AntigravityHooksInstaller.isRegistered(in: file))
        #expect(!AntigravityHooksInstaller.isRegisteredForAnyEvent(in: file))
    }

    /// A command naming Phantom's script under somebody else's hook name is not
    /// Phantom's registration: `install` would not update it and `uninstall`
    /// would not remove it, so counting it would describe a state the buttons
    /// cannot act on.
    @Test func theScriptUnderAnotherHookNameDoesNotCount() throws {
        let file = try settings("""
        {"someone-elses-hook":{"Stop":[{"type":"command",\
        "command":"'/x/phantom-tab-state.sh' done Stop"}]}}
        """)

        #expect(!AntigravityHooksInstaller.isRegistered(in: file))
        #expect(!AntigravityHooksInstaller.isRegisteredForAnyEvent(in: file))
    }

    @Test func anEmptyFileIsNotARegistration() {
        #expect(!AntigravityHooksInstaller.isRegistered(in: [:]))
        #expect(!AntigravityHooksInstaller.isRegisteredForAnyEvent(in: [:]))
        #expect(!AntigravityHooksInstaller.isRegistered(in: nil))
        #expect(!AntigravityHooksInstaller.isRegisteredForAnyEvent(in: nil))
    }

    private func registrationJSON() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: AntigravityHooksInstaller.registration)
        return try #require(String(data: data, encoding: .utf8))
    }

    // MARK: - Telling "nothing here" from "something I don't understand"

    private func temporaryFile(_ contents: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-agy-\(UUID().uuidString).json")
        if let contents {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    @Test func anAbsentFileReadsAsAnEmptyConfiguration() throws {
        let url = try temporaryFile(nil)
        let read = AntigravityHooksInstaller.readSettings(at: url)

        #expect(read != nil)
        #expect(read?.isEmpty == true)
    }

    @Test func anEmptyFileReadsAsAnEmptyConfiguration() throws {
        let url = try temporaryFile("")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(AntigravityHooksInstaller.readSettings(at: url)?.isEmpty == true)
    }

    /// The one that matters: nil, so the caller refuses to write. Antigravity's
    /// file holds every hook the reader has, keyed by name, so replacing it on
    /// a parse failure loses all of them at once.
    @Test func malformedJSONRefusesToBeRead() throws {
        let url = try temporaryFile(#"{"phantom-tab-state": {"Stop": [}}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(AntigravityHooksInstaller.readSettings(at: url) == nil)
    }

    @Test func aTopLevelArrayRefusesToBeRead() throws {
        let url = try temporaryFile(#"[{"phantom-tab-state":{}}]"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(AntigravityHooksInstaller.readSettings(at: url) == nil)
    }

    /// Other authors' hooks are read back whole, which is the property the
    /// name-scoped merge depends on.
    @Test func anotherAuthorsHooksAreReadBackWhole() throws {
        let url = try temporaryFile("""
        {"my-linter-hook":{"PostToolUse":[{"matcher":"run_command",\
        "hooks":[{"type":"command","command":"./scripts/lint.sh"}]}]}}
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let read = AntigravityHooksInstaller.readSettings(at: url)
        #expect(read?["my-linter-hook"] != nil)
        #expect(read?.count == 1)
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
