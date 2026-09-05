import Foundation
@testable import Ghostty
import Testing

/// The two agents whose hooks arrived in 0.12.0.
///
/// Scope worth stating: neither installer is exercised against disk, because
/// both write into fixed paths under the real home directory and a test that
/// installs would edit the machine it runs on. What is covered is everything
/// that decides *what gets written* — which for Kimi is the part that can
/// destroy a reader's configuration, and for Pi is the part that decides
/// whether the extension reports anything at all.
@MainActor
struct KimiPiHooksInstallerTests {
    // MARK: Kimi — the blocks it writes

    @Test func everyDocumentedEventGetsABlock() {
        let block = KimiHooksInstaller.block

        for (event, _) in KimiHooksInstaller.eventStates {
            #expect(block.contains("event = \"\(event)\""))
        }
        #expect(block.components(separatedBy: "[[hooks]]").count
            == KimiHooksInstaller.eventStates.count + 1)
    }

    /// SessionStart reports identity rather than activity, so it passes no
    /// state: an empty argument would write an empty first line *and* an
    /// argument, and the distinction is what keeps a tab with an idle agent
    /// from drawing an indicator.
    @Test func sessionStartPassesNoStateArgument() {
        let path = KimiHooksInstaller.scriptURL.path

        #expect(KimiHooksInstaller.command(for: "")
            == "'\(path)' --agent kimi --session-key session_id")
        #expect(KimiHooksInstaller.command(for: "working")
            == "'\(path)' working --agent kimi --session-key session_id")
    }

    /// A home directory with a quote or a backslash in it makes the whole file
    /// unparseable when written raw — and that file holds the reader's model,
    /// permissions and MCP settings, not just this hook.
    @Test func aPathWithQuotesCannotBreakTheFile() {
        #expect(KimiHooksInstaller.tomlString(#"a"b"#) == #""a\"b""#)
        #expect(KimiHooksInstaller.tomlString(#"a\b"#) == #""a\\b""#)
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

    @Test func removingPhantomLeavesTheReadersFileAlone() {
        let installed = readerConfig + "\n\n" + KimiHooksInstaller.block + "\n"

        let cleaned = KimiHooksInstaller.removed(from: installed)

        #expect(cleaned.contains("# my own settings, hand written"))
        #expect(cleaned.contains("model = \"kimi-k2\""))
        #expect(cleaned.contains("my-own-audit.sh"))
        #expect(cleaned.contains("[permissions]"))
        #expect(cleaned.contains("mode = \"ask\""))
        #expect(!cleaned.contains(KimiHooksInstaller.scriptName))
    }

    /// The reader's own hook is a `[[hooks]]` block too, so structure cannot
    /// tell them apart — only the command inside can.
    @Test func theReadersOwnHookIsNotMistakenForOurs() {
        #expect(KimiHooksInstaller.isPhantomBlock([
            "event = \"Stop\"", "command = \"~/bin/my-own-audit.sh\"",
        ]) == false)

        #expect(KimiHooksInstaller.isPhantomBlock([
            "event = \"Stop\"",
            "command = \"/x/\(KimiHooksInstaller.scriptName) done\"",
        ]))
    }

    @Test func aFileWithNothingOfOursReadsAsNotRegistered() {
        #expect(KimiHooksInstaller.isRegistered(in: readerConfig) == false)
    }

    @Test func aFileWithOurBlocksReadsAsRegistered() {
        let installed = readerConfig + "\n\n" + KimiHooksInstaller.block
        #expect(KimiHooksInstaller.isRegistered(in: installed))
    }

    /// Installing twice must not stack two copies, which is what the remove
    /// before the append is for.
    @Test func installingOverAnInstallationDoesNotDouble() {
        let once = KimiHooksInstaller.removed(from: readerConfig) + "\n\n"
            + KimiHooksInstaller.block
        let twice = KimiHooksInstaller.removed(from: once) + "\n\n" + KimiHooksInstaller.block

        let blocks = twice.components(separatedBy: "[[hooks]]").count - 1

        #expect(blocks == KimiHooksInstaller.eventStates.count + 1)
    }

    // MARK: Pi — the extension it ships

    /// The directory is Pi's and the name is this build's, and only the first
    /// half can be written out here. A second build gives the file a variant
    /// of its own — `phantom-debug.ts` — so a literal would pin one build's
    /// spelling and fail in the other, which is what it did.
    @Test func theExtensionGoesWherePiLooksForIt() {
        let path = PiHooksInstaller.extensionURL.path
        #expect(path.hasSuffix("/.pi/agent/extensions/\(PiHooksInstaller.extensionName)"))
        #expect(PiHooksInstaller.extensionName.hasSuffix(".ts"))
        #expect(PiHooksInstaller.extensionName.hasPrefix("phantom"))
    }

    @Test func itSubscribesToEveryEventItClaims() {
        for event in PiHooksInstaller.events {
            #expect(PiHooksInstaller.source.contains("pi.on(\"\(event)\""))
        }
    }

    /// The state words are the app's own vocabulary, and the agent line is
    /// what tells the sidebar which agent it is looking at.
    @Test func itReportsTheStatesTheAppReads() {
        let source = PiHooksInstaller.source

        #expect(source.contains("agent=pi"))
        #expect(source.contains("report(\"working\")"))
        #expect(source.contains("report(\"done\")"))
        #expect(source.contains("report(\"ended\")"))
        #expect(source.contains("report(\"\")"))
    }

    /// Pi's `--session` takes a path or an id, but the app refuses anything
    /// holding a slash — so writing a path would look like an id on disk and
    /// be dropped on read, leaving the tab quietly resuming with --continue.
    @Test func itWritesAnIdRatherThanAPath() {
        let source = PiHooksInstaller.source

        #expect(source.contains("split(\"/\").pop()"))
        #expect(source.contains("A-Za-z0-9._-"))
        #expect(source.contains("startsWith(\"-\")"))
    }

    /// The bug this shipped with. Pi names a session `<timestamp>_<uuid>` and
    /// matches on the UUID, so passing the whole stem answered "No session
    /// found matching" and started a fresh conversation — a restored tab
    /// losing its history without saying so.
    @Test func itTakesTheUuidOutOfPisSessionFileName() {
        #expect(PiHooksInstaller.source.contains("[0-9a-fA-F]{8}-"))
    }

    /// No import of Pi's own package, so the file cannot fail to resolve, and
    /// no npm entry is needed to ship it.
    @Test func itNeedsNothingInstalledToRun() {
        let source = PiHooksInstaller.source

        #expect(!source.contains("@earendil-works"))
        #expect(source.contains("node:fs"))
    }

    /// The same atomic write the shell scripts do, and for the same reason.
    @Test func itWritesThroughATemporaryName() {
        let source = PiHooksInstaller.source

        #expect(source.contains("process.pid"))
        #expect(source.contains("renameSync"))
    }

    /// Without the tab-state file in the environment there is nothing to
    /// report to, and the extension has to be inert rather than throwing
    /// inside somebody's agent.
    @Test func itDoesNothingOutsideAPhantomTab() {
        #expect(PiHooksInstaller.source.contains("if (!stateFile) return;"))
    }

    /// A config that points at a script somewhere else is stale, because the
    /// hook fires and finds nothing. This is what moving the app does.
    @Test func aConfigPointingElsewhereIsStale() {
        let elsewhere = """
        [[hooks]]
        event = "Stop"
        command = "/old/location/\(KimiHooksInstaller.scriptName) done"
        """

        #expect(KimiHooksInstaller.isRegistered(in: elsewhere))
        #expect(!elsewhere.contains(KimiHooksInstaller.scriptURL.path))
    }
}
