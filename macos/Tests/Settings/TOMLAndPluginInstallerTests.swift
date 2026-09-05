import Foundation
@testable import Ghostty
import Testing

@MainActor
struct TOMLAndPluginInstallerTests {
    private let home = URL(fileURLWithPath: "/h", isDirectory: true)

    private func kimi(home: URL? = nil) throws -> TOMLHooksInstaller {
        try #require(TOMLHooksInstaller(
            descriptor: AgentRegistry.kimi,
            environment: [:],
            home: home ?? self.home,
            bundleID: PhantomBuild.releaseBundleID))
    }

    private func plugin(_ descriptor: AgentDescriptor, home: URL? = nil) throws -> PluginFileInstaller {
        try #require(PluginFileInstaller(
            descriptor: descriptor,
            environment: [:],
            home: home ?? self.home,
            bundleID: PhantomBuild.releaseBundleID))
    }

    // MARK: Kimi — the blocks it writes

    @Test func kimiWritesBesideItsScript() throws {
        let kimi = try self.kimi()

        #expect(kimi.configURL.path == "/h/.kimi-code/config.toml")
        #expect(kimi.scriptURL.path == "/h/.kimi-code/phantom-tab-state.sh")

        let relocated = try #require(TOMLHooksInstaller(
            descriptor: AgentRegistry.kimi,
            environment: ["KIMI_CODE_HOME": "/opt/kimi"],
            home: home,
            bundleID: PhantomBuild.releaseBundleID))
        #expect(relocated.configURL.path == "/opt/kimi/config.toml")
    }

    @Test func everyDocumentedEventGetsABlock() throws {
        let kimi = try self.kimi()
        let block = kimi.block

        for (event, _) in kimi.eventStates {
            #expect(block.contains("event = \"\(event)\""))
        }
        #expect(block.components(separatedBy: "[[hooks]]").count == kimi.eventStates.count + 1)
    }

    /// SessionStart reports identity rather than activity, so it passes no
    /// state word: the descriptor's options follow the script either way.
    @Test func sessionStartPassesNoStateArgument() throws {
        let kimi = try self.kimi()

        #expect(kimi.command(for: .init("SessionStart", ""))
            == "'/h/.kimi-code/phantom-tab-state.sh' --agent kimi --session-key session_id")
        #expect(kimi.command(for: .init("UserPromptSubmit", "working"))
            == "'/h/.kimi-code/phantom-tab-state.sh' working --agent kimi --session-key session_id")
    }

    /// A home directory with a quote or a backslash in it makes the whole file
    /// unparseable when written raw — and that file holds the reader's model,
    /// permissions and MCP settings, not just this hook.
    @Test func aPathWithQuotesCannotBreakTheFile() {
        #expect(TOMLHooksInstaller.tomlString(#"a"b"#) == #""a\"b""#)
        #expect(TOMLHooksInstaller.tomlString(#"a\b"#) == #""a\\b""#)
    }

    // MARK: Kimi — what it must never destroy

    private var readerConfig: String {
        """
        # my own settings, hand written
        model = "kimi-k2"

        [[hooks]]
        event = "PreToolUse"
        command = "~/bin/my-own-audit.sh"

        [permissions]
        mode = "ask"
        """
    }

    @Test func removingPhantomLeavesTheReadersFileAlone() throws {
        let kimi = try self.kimi()
        let installed = readerConfig + "\n\n" + kimi.block + "\n"

        let cleaned = kimi.removed(from: installed)

        #expect(cleaned.contains("# my own settings, hand written"))
        #expect(cleaned.contains("model = \"kimi-k2\""))
        #expect(cleaned.contains("my-own-audit.sh"))
        #expect(cleaned.contains("[permissions]"))
        #expect(cleaned.contains("mode = \"ask\""))
        #expect(!cleaned.contains(kimi.scriptName))
    }

    @Test func theReadersOwnHookIsNotMistakenForOurs() throws {
        let kimi = try self.kimi()

        #expect(kimi.isPhantomBlock([
            "event = \"Stop\"", "command = \"~/bin/my-own-audit.sh\"",
        ]) == false)

        #expect(kimi.isPhantomBlock([
            "event = \"Stop\"",
            "command = \"/x/\(kimi.scriptName) done\"",
        ]))
    }

    @Test func aFileWithNothingOfOursReadsAsNotRegistered() throws {
        #expect(try self.kimi().isRegistered(in: readerConfig) == false)
    }

    @Test func aFileWithOurBlocksReadsAsRegistered() throws {
        let kimi = try self.kimi()
        #expect(kimi.isRegistered(in: readerConfig + "\n\n" + kimi.block))
    }

    @Test func installingOverAnInstallationDoesNotDouble() throws {
        let kimi = try self.kimi()
        let once = kimi.installed(into: readerConfig, scriptPath: kimi.scriptURL.path)
        let twice = kimi.installed(into: once, scriptPath: kimi.scriptURL.path)

        let blocks = twice.components(separatedBy: "[[hooks]]").count - 1

        #expect(blocks == kimi.eventStates.count + 1)
    }

    /// A config that points at a script somewhere else is stale, because the
    /// hook fires and finds nothing. This is what moving the app does.
    @Test func aConfigPointingElsewhereIsStale() throws {
        let kimi = try self.kimi()
        let elsewhere = """
        [[hooks]]
        event = "Stop"
        command = "/old/location/\(kimi.scriptName) done"
        """

        #expect(kimi.isRegistered(in: elsewhere))
        #expect(!elsewhere.contains(kimi.scriptURL.path))
    }

    @Test func kimiInstallsIntoAReadersConfigAndTakesItselfBackOut() throws {
        try withTemporaryHome { temporaryHome in
            let kimi = try self.kimi(home: temporaryHome)
            try FileManager.default.createDirectory(
                at: kimi.directory, withIntermediateDirectories: true)
            try readerConfig.write(to: kimi.configURL, atomically: true, encoding: .utf8)

            #expect(!kimi.isInstalled)
            #expect(kimi.install(), Comment(rawValue: kimi.lastError ?? ""))
            #expect(kimi.isInstalled)
            #expect(!kimi.isStale)

            let written = try String(contentsOf: kimi.configURL, encoding: .utf8)
            #expect(written.hasPrefix(readerConfig))
            #expect(written.contains(kimi.scriptURL.path))

            #expect(kimi.uninstall())
            #expect(!kimi.isInstalled)
            #expect(try String(contentsOf: kimi.configURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) == readerConfig)
            #expect(!FileManager.default.fileExists(atPath: kimi.scriptURL.path))
        }
    }

    // MARK: Pi and OpenCode — the files they ship

    @Test func theExtensionGoesWherePiLooksForIt() throws {
        let pi = try plugin(AgentRegistry.pi)

        #expect(pi.fileURL.path == "/h/.pi/agent/extensions/phantom.ts")
        #expect(pi.fileName.hasSuffix(".ts"))
        #expect(pi.fileName.hasPrefix("phantom"))

        let debug = try #require(PluginFileInstaller(
            descriptor: AgentRegistry.pi,
            environment: [:],
            home: home,
            bundleID: "com.ipetinate.phantom.debug"))
        #expect(debug.fileName == "phantom-debug.ts")
    }

    @Test func thePluginGoesWhereOpenCodeLooksForIt() throws {
        let opencode = try plugin(AgentRegistry.opencode)

        #expect(opencode.fileURL.path == "/h/.config/opencode/plugins/phantom-integration.js")
    }

    @Test func itSubscribesToEveryEventItClaims() throws {
        let pi = try plugin(AgentRegistry.pi)

        for event in pi.events {
            #expect(pi.body.contains("pi.on(\"\(event)\""))
        }
    }

    /// The state words are the app's own vocabulary, and the agent line is
    /// what tells the sidebar which agent it is looking at.
    @Test func itReportsTheStatesTheAppReads() throws {
        let source = try plugin(AgentRegistry.pi).body

        #expect(source.contains("agent=pi"))
        #expect(!source.contains(HooksIntegration.PluginFile.agentPlaceholder))
        #expect(source.contains("process.env.GHOSTTY_TAB_STATE_FILE"))
        #expect(source.contains("report(\"working\")"))
        #expect(source.contains("report(\"done\")"))
        #expect(source.contains("report(\"ended\")"))
        #expect(source.contains("report(\"\")"))
    }

    @Test func theOpenCodePluginNamesItsOwnAgent() throws {
        let source = try plugin(AgentRegistry.opencode).body

        #expect(source.contains("\"agent=opencode\""))
        #expect(!source.contains(HooksIntegration.PluginFile.stateFileVariablePlaceholder))
        #expect(source.contains("process.env.GHOSTTY_TAB_STATE_FILE"))
    }

    /// Pi's `--session` takes a path or an id, but the app refuses anything
    /// holding a slash — so writing a path would look like an id on disk and
    /// be dropped on read, leaving the tab quietly resuming with --continue.
    @Test func itWritesAnIdRatherThanAPath() throws {
        let source = try plugin(AgentRegistry.pi).body

        #expect(source.contains("split(\"/\").pop()"))
        #expect(source.contains("A-Za-z0-9._-"))
        #expect(source.contains("startsWith(\"-\")"))
        #expect(source.contains("[0-9a-fA-F]{8}-"))
    }

    @Test func itNeedsNothingInstalledToRun() throws {
        let source = try plugin(AgentRegistry.pi).body

        #expect(!source.contains("@earendil-works"))
        #expect(source.contains("node:fs"))
    }

    @Test func itWritesThroughATemporaryName() throws {
        let source = try plugin(AgentRegistry.pi).body

        #expect(source.contains("process.pid"))
        #expect(source.contains("renameSync"))
    }

    @Test func itDoesNothingOutsideAPhantomTab() throws {
        #expect(try plugin(AgentRegistry.pi).body.contains("if (!stateFile) return;"))
    }

    @Test func aPluginInstallsAndUninstallsAndAnOlderCopyIsStale() throws {
        try withTemporaryHome { temporaryHome in
            let pi = try plugin(AgentRegistry.pi, home: temporaryHome)

            #expect(!pi.isInstalled)
            #expect(!pi.isStale)
            #expect(pi.uninstall())

            #expect(pi.install(), Comment(rawValue: pi.lastError ?? ""))
            #expect(pi.isInstalled)
            #expect(!pi.isStale)
            #expect(try String(contentsOf: pi.fileURL, encoding: .utf8) == pi.body)

            try "// older".write(to: pi.fileURL, atomically: true, encoding: .utf8)
            #expect(pi.isStale)
            #expect(pi.repairIfStale())
            #expect(!pi.isStale)

            #expect(pi.uninstall())
            #expect(!pi.isInstalled)
        }
    }

    private func withTemporaryHome(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
