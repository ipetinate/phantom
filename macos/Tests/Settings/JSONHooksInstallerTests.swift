import Foundation
@testable import Ghostty
import Testing

/// The JSON hooks engine, driven by the three descriptors that use it.
///
/// Claude Code and Codex share one top-level `hooks` key with everybody else's
/// hooks and nest each handler in a `{ hooks: [...] }` group; Antigravity keys
/// its file by a name the author picks and owns that whole key, with flat
/// handlers under each event. Reading Phantom's own registration out of a file
/// full of somebody else's is therefore a different operation for the two
/// shapes, and each gets its own fixtures here.
///
/// Nothing touches the reader's home: every engine is built against `/h`, an
/// empty environment and the release bundle id, so the paths it derives are
/// the same on every machine and in every build.
@MainActor
struct JSONHooksInstallerTests {
    private let home = URL(fileURLWithPath: "/h", isDirectory: true)

    private func engine(_ descriptor: AgentDescriptor) throws -> JSONHooksInstaller {
        try #require(JSONHooksInstaller(
            descriptor: descriptor,
            environment: [:],
            home: home,
            bundleID: PhantomBuild.releaseBundleID))
    }

    private func settings(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: - Where each one writes

    @Test func eachDescriptorResolvesItsOwnFiles() throws {
        let claude = try engine(AgentRegistry.claude)
        let codex = try engine(AgentRegistry.codex)
        let antigravity = try engine(AgentRegistry.antigravity)

        #expect(claude.settingsURL.path == "/h/.claude/settings.json")
        #expect(claude.scriptURL.path == "/h/.claude/hooks/phantom-tab-state.sh")
        #expect(codex.settingsURL.path == "/h/.codex/hooks.json")
        #expect(codex.scriptURL.path == "/h/.codex/phantom-tab-state.sh")
        #expect(antigravity.settingsURL.path == "/h/.gemini/config/hooks.json")
        #expect(antigravity.scriptURL.path == "/h/.gemini/config/phantom-tab-state.sh")
    }

    @Test func codexFollowsItsHomeVariable() throws {
        let codex = try #require(JSONHooksInstaller(
            descriptor: AgentRegistry.codex,
            environment: ["CODEX_HOME": "/srv/codex"],
            home: home,
            bundleID: PhantomBuild.releaseBundleID))

        #expect(codex.settingsURL.path == "/srv/codex/hooks.json")
        #expect(codex.scriptURL.path == "/srv/codex/phantom-tab-state.sh")
    }

    @Test func aDebugBuildNamesItsOwnScript() throws {
        let debug = try #require(JSONHooksInstaller(
            descriptor: AgentRegistry.claude,
            environment: [:],
            home: home,
            bundleID: "com.ipetinate.phantom.debug"))

        #expect(debug.scriptName == "phantom-debug-tab-state.sh")
        #expect(debug.legacyScriptNames.isEmpty)
        #expect(try engine(AgentRegistry.claude).legacyScriptNames == ["ghostty-tab-state.sh"])
    }

    // MARK: - Claude Code: a shared key, grouped entries

    /// A settings file registering the script for one event only — `Stop`.
    private func hooksSettings(registeredCommand: String?) -> [String: Any] {
        var hooks: [String: Any] = [:]
        if let registeredCommand {
            hooks["Stop"] = [
                [
                    "hooks": [
                        ["type": "command", "command": registeredCommand],
                    ]
                ]
            ]
        }
        return ["hooks": hooks]
    }

    /// A settings file registering the script for every event this build
    /// reports — what a current install actually leaves behind.
    private func fullyRegisteredSettings(
        _ claude: JSONHooksInstaller,
        omitting omitted: Set<String> = []
    ) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for (event, state) in claude.eventStates where !omitted.contains(event) {
            hooks[event] = [
                ["hooks": [["type": "command", "command": "'/h/\(claude.scriptName)' \(state)"]]]
            ]
        }
        return ["hooks": hooks]
    }

    @Test func detectsARegisteredHookRegardlessOfJSONEscaping() throws {
        let claude = try engine(AgentRegistry.claude)
        let path = "/Users/isac.petinate/.claude/hooks/\(claude.scriptName)"
        let settings = hooksSettings(registeredCommand: "'\(path)' done")

        #expect(claude.isRegisteredForAnyEvent(in: settings))
    }

    @Test func noHooksKeyIsNotRegistered() throws {
        let claude = try engine(AgentRegistry.claude)

        #expect(!claude.isRegistered(in: [:]))
        #expect(!claude.isRegisteredForAnyEvent(in: [:]))
    }

    @Test func emptyHooksAreNotRegistered() throws {
        let claude = try engine(AgentRegistry.claude)
        let settings = hooksSettings(registeredCommand: nil)

        #expect(!claude.isRegistered(in: settings))
        #expect(!claude.isRegisteredForAnyEvent(in: settings))
    }

    @Test func aDifferentCommandIsNotRegistered() throws {
        let claude = try engine(AgentRegistry.claude)
        let settings = hooksSettings(registeredCommand: "'/some/other/script.sh' done")

        #expect(!claude.isRegistered(in: settings))
        #expect(!claude.isRegisteredForAnyEvent(in: settings))
    }

    @Test func missingOrInvalidSettingsIsNotRegistered() throws {
        let claude = try engine(AgentRegistry.claude)

        #expect(!claude.isRegistered(in: nil))
        #expect(!claude.isRegisteredForAnyEvent(in: nil))
    }

    @Test func aRegisteredHookAmongUnrelatedKeysIsStillDetected() throws {
        let claude = try engine(AgentRegistry.claude)
        var settings = fullyRegisteredSettings(claude)
        settings["env"] = ["SOME_VAR": "value"]
        settings["theme"] = "dark"

        #expect(claude.isRegistered(in: settings))
    }

    @Test func everyEventRegisteredCountsAsInstalled() throws {
        let claude = try engine(AgentRegistry.claude)

        #expect(claude.isRegistered(in: fullyRegisteredSettings(claude)))
    }

    /// The bug: one event out of nine used to satisfy the check. An install
    /// performed by an older Phantom therefore counted as current forever, so
    /// the events added since were never registered — and the states behind
    /// them became unreachable.
    @Test func aPartialRegistrationIsNotInstalled() throws {
        let claude = try engine(AgentRegistry.claude)
        let partial = fullyRegisteredSettings(
            claude, omitting: ["Notification", "PermissionDenied", "StopFailure"])

        #expect(!claude.isRegistered(in: partial))
    }

    /// Exactly the shape found in the user's `settings.json`: six events
    /// registered, which the old check called installed.
    @Test func thePartialInstallationFoundInTheWildIsDetectedAsIncomplete() throws {
        let claude = try engine(AgentRegistry.claude)
        let partial = fullyRegisteredSettings(claude, omitting: [
            "SessionStart", "PreCompact", "PostCompact", "Notification",
            "PermissionDenied", "StopFailure",
        ])

        #expect((partial["hooks"] as? [String: Any])?.count == 6)
        #expect(claude.eventStates.count == 12)
        #expect(!claude.isRegistered(in: partial))
        #expect(claude.isRegisteredForAnyEvent(in: partial))
    }

    @Test func aPartialRemovalIsNotACompleteRemoval() throws {
        let claude = try engine(AgentRegistry.claude)
        let partial = fullyRegisteredSettings(claude, omitting: ["Stop"])

        #expect(!claude.isRegistered(in: partial))
        #expect(claude.isRegisteredForAnyEvent(in: partial))
    }

    @Test func removingEveryEventLeavesNothingRegistered() throws {
        let claude = try engine(AgentRegistry.claude)
        let empty = fullyRegisteredSettings(claude, omitting: Set(claude.eventStates.map(\.event)))

        #expect(!claude.isRegisteredForAnyEvent(in: empty))
    }

    /// The registration's own product reads back as installed, and its own
    /// removal reads back as gone — for a shared key holding another hook.
    @Test func aSharedKeyRoundTrips() throws {
        let codex = try engine(AgentRegistry.codex)
        let before = try settings(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/other.sh"}]}]}}"#)

        let registered = codex.registered(into: before)
        #expect(codex.isRegistered(in: registered))

        let removed = codex.removed(from: registered)
        #expect(!codex.isRegisteredForAnyEvent(in: removed))
        #expect(codex.commands(in: removed, event: "Stop") == ["/other.sh"])
    }

    // MARK: - Antigravity: an owned key, flat handlers

    @Test func noToolPermissionEventIsRegistered() throws {
        let events = try engine(AgentRegistry.antigravity).eventStates.map(\.event)

        #expect(!events.contains("PreToolUse"))
        #expect(!events.contains("PostInvocation"))
    }

    @Test func everyRegisteredEventIsARealAntigravityEvent() throws {
        let known: Set<String> = [
            "PreToolUse", "PostToolUse", "PreInvocation", "PostInvocation", "Stop",
        ]
        let events = try engine(AgentRegistry.antigravity).eventStates

        for (event, _) in events {
            #expect(known.contains(event), "\(event) is not an Antigravity hook event")
        }
        #expect(!events.isEmpty)
    }

    @Test func theRegistrationUsesTheUngroupedHandlerShape() throws {
        let antigravity = try engine(AgentRegistry.antigravity)
        let registration = try #require(
            antigravity.registered(into: [:])["phantom-tab-state"] as? [String: Any])

        #expect(registration.count == antigravity.eventStates.count)

        for (event, _) in antigravity.eventStates {
            let handlers = try #require(
                registration[event] as? [[String: Any]],
                "\(event) is not a list of handlers")

            #expect(handlers.count == 1)
            #expect(handlers.first?["type"] as? String == "command")
            #expect(handlers.first?["matcher"] == nil)
            #expect(handlers.first?["hooks"] == nil)
        }
    }

    @Test func theRegistrationSerializesToJSON() throws {
        let payload = try engine(AgentRegistry.antigravity).registered(into: [:])

        #expect(JSONSerialization.isValidJSONObject(payload))

        let data = try JSONSerialization.data(withJSONObject: payload)
        let round = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(round?["phantom-tab-state"] != nil)
    }

    @Test func aCompleteRegistrationReadsAsInstalled() throws {
        let antigravity = try engine(AgentRegistry.antigravity)
        let file = antigravity.registered(into: ["my-linter-hook": ["PostToolUse": []]])

        #expect(antigravity.isRegistered(in: file))
        #expect(antigravity.isRegisteredForAnyEvent(in: file))
        #expect(file["my-linter-hook"] != nil)
    }

    @Test func aPartialRegistrationIsIncompleteButPresent() throws {
        let antigravity = try engine(AgentRegistry.antigravity)
        let file = try settings("""
        {"phantom-tab-state":{"Stop":[{"type":"command",\
        "command":"'/x/\(antigravity.scriptName)' done Stop"}]}}
        """)

        #expect(!antigravity.isRegistered(in: file))
        #expect(antigravity.isRegisteredForAnyEvent(in: file))
    }

    @Test func anotherAuthorsHooksAreNotPhantoms() throws {
        let antigravity = try engine(AgentRegistry.antigravity)
        let file = try settings("""
        {"my-linter-hook":{"PostToolUse":[{"matcher":"run_command",\
        "hooks":[{"type":"command","command":"./scripts/lint.sh"}]}]},\
        "safety-gate":{"enabled":false,"PreToolUse":[{"matcher":"run_command",\
        "hooks":[{"command":"./scripts/safety-check.sh"}]}]}}
        """)

        #expect(!antigravity.isRegistered(in: file))
        #expect(!antigravity.isRegisteredForAnyEvent(in: file))
    }

    @Test func theScriptUnderAnotherHookNameDoesNotCount() throws {
        let antigravity = try engine(AgentRegistry.antigravity)
        let file = try settings("""
        {"someone-elses-hook":{"Stop":[{"type":"command",\
        "command":"'/x/phantom-tab-state.sh' done Stop"}]}}
        """)

        #expect(!antigravity.isRegistered(in: file))
        #expect(!antigravity.isRegisteredForAnyEvent(in: file))
    }

    @Test func removingTheOwnedKeyLeavesTheOthers() throws {
        let antigravity = try engine(AgentRegistry.antigravity)
        let file = antigravity.registered(into: ["my-linter-hook": ["PostToolUse": []]])
        let removed = antigravity.removed(from: file)

        #expect(removed["phantom-tab-state"] == nil)
        #expect(removed["my-linter-hook"] != nil)
        #expect(!antigravity.isRegisteredForAnyEvent(in: removed))
    }

    @Test func anEmptyFileIsNotARegistration() throws {
        let antigravity = try engine(AgentRegistry.antigravity)

        #expect(!antigravity.isRegistered(in: [:]))
        #expect(!antigravity.isRegisteredForAnyEvent(in: [:]))
        #expect(!antigravity.isRegistered(in: nil))
        #expect(!antigravity.isRegisteredForAnyEvent(in: nil))
    }

    // MARK: - Telling "nothing here" from "something I don't understand"

    private func temporaryFile(_ contents: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-hooks-\(UUID().uuidString).json")
        if let contents {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    @Test func anAbsentFileReadsAsAnEmptyConfiguration() throws {
        let read = JSONHooksInstaller.readSettings(at: try temporaryFile(nil))

        #expect(read != nil)
        #expect(read?.isEmpty == true)
    }

    @Test func aValidObjectIsReadBackWhole() throws {
        let url = try temporaryFile(#"{"hooks":{"Stop":[]},"model":"gpt-5"}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        let read = JSONHooksInstaller.readSettings(at: url)
        #expect(read?["model"] as? String == "gpt-5")
        #expect(read?["hooks"] != nil)
    }

    /// The one that mattered: nil, so the caller refuses to write. A file that
    /// read as *nothing* was replaced by Phantom's hooks, atomically and while
    /// reporting success.
    @Test func malformedJSONRefusesToBeRead() throws {
        let url = try temporaryFile(#"{"hooks": {"Stop": [}}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(JSONHooksInstaller.readSettings(at: url) == nil)
    }

    @Test func aTopLevelArrayRefusesToBeRead() throws {
        let url = try temporaryFile(#"[{"hooks":{}}]"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(JSONHooksInstaller.readSettings(at: url) == nil)
    }

    @Test func plainTextRefusesToBeRead() throws {
        let url = try temporaryFile("# not json at all\n")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(JSONHooksInstaller.readSettings(at: url) == nil)
    }

    @Test func anEmptyFileReadsAsAnEmptyConfiguration() throws {
        let url = try temporaryFile("")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(JSONHooksInstaller.readSettings(at: url)?.isEmpty == true)
    }

    @Test func anotherAuthorsHooksAreReadBackWhole() throws {
        let url = try temporaryFile("""
        {"my-linter-hook":{"PostToolUse":[{"matcher":"run_command",\
        "hooks":[{"type":"command","command":"./scripts/lint.sh"}]}]}}
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let read = JSONHooksInstaller.readSettings(at: url)
        #expect(read?["my-linter-hook"] != nil)
        #expect(read?.count == 1)
    }

    // MARK: - Installing into a directory of our own

    private func withTemporaryHome(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func installingWritesTheScriptAndTheRegistrationAndUninstallingTakesThemBack() throws {
        try withTemporaryHome { temporaryHome in
            let claude = try #require(JSONHooksInstaller(
                descriptor: AgentRegistry.claude,
                environment: [:],
                home: temporaryHome,
                bundleID: PhantomBuild.releaseBundleID))
            try #"{"theme":"dark"}"#.write(
                to: claude.settingsURL, atomically: true, encoding: .utf8)

            #expect(!claude.isInstalled)
            #expect(claude.install(), Comment(rawValue: claude.lastError ?? ""))
            #expect(claude.isInstalled)
            #expect(!claude.isStale)
            #expect(try String(contentsOf: claude.scriptURL, encoding: .utf8) == TabStateScript.body)

            let written = JSONHooksInstaller.readSettings(at: claude.settingsURL)
            #expect(written?["theme"] as? String == "dark")
            #expect(claude.isRegistered(in: written))

            #expect(claude.uninstall(), Comment(rawValue: claude.lastError ?? ""))
            #expect(!claude.isInstalled)
            #expect(!FileManager.default.fileExists(atPath: claude.scriptURL.path))
            #expect(JSONHooksInstaller.readSettings(at: claude.settingsURL)?["theme"] as? String == "dark")
        }
    }

    /// The migration this release performs: a script from an older build is
    /// stale, and the repair rewrites it and re-registers every event.
    @Test func anOlderScriptIsStaleAndRepairRewritesIt() throws {
        try withTemporaryHome { temporaryHome in
            let codex = try #require(JSONHooksInstaller(
                descriptor: AgentRegistry.codex,
                environment: ["CODEX_HOME": temporaryHome.path],
                home: temporaryHome,
                bundleID: PhantomBuild.releaseBundleID))
            try FileManager.default.createDirectory(
                at: codex.directory, withIntermediateDirectories: true)
            try "#!/bin/bash\necho old\n".write(to: codex.scriptURL, atomically: true, encoding: .utf8)
            let partial = codex.registered(into: [:])
            let data = try JSONSerialization.data(withJSONObject: partial)
            try data.write(to: codex.settingsURL)

            #expect(codex.isStale)
            #expect(codex.repairIfStale(), Comment(rawValue: codex.lastError ?? ""))
            #expect(!codex.isStale)
            #expect(try String(contentsOf: codex.scriptURL, encoding: .utf8) == TabStateScript.body)
        }
    }

    @Test func repairNeverInstallsUninvited() throws {
        try withTemporaryHome { temporaryHome in
            let claude = try #require(JSONHooksInstaller(
                descriptor: AgentRegistry.claude,
                environment: [:],
                home: temporaryHome,
                bundleID: PhantomBuild.releaseBundleID))

            #expect(!claude.repairIfStale())
            #expect(!FileManager.default.fileExists(atPath: claude.scriptURL.path))
            #expect(!FileManager.default.fileExists(atPath: claude.settingsURL.path))
        }
    }

    @Test func aMalformedSettingsFileIsLeftAlone() throws {
        try withTemporaryHome { temporaryHome in
            let claude = try #require(JSONHooksInstaller(
                descriptor: AgentRegistry.claude,
                environment: [:],
                home: temporaryHome,
                bundleID: PhantomBuild.releaseBundleID))
            try FileManager.default.createDirectory(
                at: claude.directory, withIntermediateDirectories: true)
            try "{ not json".write(to: claude.settingsURL, atomically: true, encoding: .utf8)

            #expect(!claude.install())
            #expect(claude.lastError?.contains("settings.json") == true)
            #expect(try String(contentsOf: claude.settingsURL, encoding: .utf8) == "{ not json")
        }
    }
}
