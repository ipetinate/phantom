import Foundation
@testable import Ghostty
import Testing

/// Who formats a file when the project declares no Prettier and the language
/// server offers no formatting.
///
/// The case it was written for: `marksman` does not format, and a `.md` file
/// in a repository without a `.prettierrc` answered ⇧⌘F by naming `marksman`
/// — the wrong tool, for a file the project formats with `prettier -w .`.
struct EditorFormatRouteTests {
    private func route(
        _ trigger: EditorFormatTrigger = .command,
        knows: Bool = true,
        server: LSPServerStatus? = .running,
        formats: Bool = false,
        timedOut: Bool = false
    ) -> Bool {
        EditorFormatRoute.usesPrettierFromPath(
            trigger: trigger,
            prettierKnowsTheFile: knows,
            server: server,
            serverFormats: formats,
            handshakeTimedOut: timedOut)
    }

    // MARK: When Prettier gets the last word

    @Test func markdownWhoseServerDoesNotFormatGoesToPrettier() {
        #expect(route())
    }

    /// A language with no server at all — nothing else was ever going to
    /// answer.
    @Test func aFileWithNoServerConfiguredGoesToPrettier() {
        #expect(route(server: nil))
    }

    /// A sentence about an uninstalled `marksman` is not what somebody asking
    /// to format Markdown needs.
    @Test func aBrokenServerDoesNotBlockPrettier() {
        #expect(route(server: .notInstalled))
        #expect(route(server: .crashed(status: 1)))
        #expect(route(server: .failedToStart(reason: "no binary")))
        #expect(route(server: .unresponsive))
        #expect(route(server: .notApproved))
    }

    // MARK: When it does not

    /// The rule the save path keeps: nothing rewrites a project's files
    /// unless the project asked for it. ⇧⌘F is the reader asking by hand;
    /// ⌘S is the editor's own idea.
    @Test func aSaveNeverTakesThisRoute() {
        #expect(!route(.save))
        #expect(!route(.save, server: nil))
    }

    /// A `.rs` file in a repository that also holds JavaScript. Prettier has
    /// no parser for it, and claiming it would be an error banner.
    @Test func aFilePrettierDoesNotKnowIsLeftAlone() {
        #expect(!route(knows: false))
    }

    /// The server that does format keeps formatting. This route is a fallback,
    /// not a preference — a TypeScript project with no Prettier config still
    /// gets `tsserver`.
    @Test func aServerThatFormatsIsNotOverridden() {
        #expect(!route(formats: true))
    }

    /// `hasCapability` answers false for "has not said yet" exactly as it does
    /// for "does not have it", so a server mid-handshake would otherwise be
    /// read as a server without a formatter — and ⇧⌘F in the first seconds of
    /// a TypeScript file would format it with Prettier's defaults instead.
    @Test func aServerStillStartingIsWaitedFor() {
        #expect(!route(server: .starting))
    }

    // MARK: The formatters that are a command

    private func external(server: LSPServerStatus? = .running, formats: Bool = false) -> Bool {
        EditorFormatRoute.usesExternalFormatter(server: server, serverFormats: formats)
    }

    /// Python is the case: `pyright` has no formatter at all, so nothing else
    /// was ever going to answer.
    @Test func aLanguageWhoseServerDoesNotFormatGoesToItsOwnTool() {
        #expect(external())
        #expect(external(server: nil))
        #expect(external(server: .notInstalled))
    }

    /// The difference from the Prettier fallback, and the deliberate one: a
    /// save takes this route. These tools are the only formatter their
    /// language has, which is where the language server's own formatter
    /// stands — and that has always run on a save.
    @Test func theTriggerDoesNotDecideThisOne() {
        #expect(external())
    }

    /// A server that formats is the project's own answer.
    @Test func aServerThatFormatsKeepsFormatting() {
        #expect(!external(formats: true))
    }

    @Test func aServerStillStartingIsWaitedForHereToo() {
        #expect(!external(server: .starting))
    }

    // MARK: The handshake the reader pressed a key during

    /// The bug this pair exists for. The first ⇧⌘F in a freshly opened
    /// Markdown file lands in the second between `marksman` launching and it
    /// reporting what it can do, and the reader was told that server does not
    /// offer formatting — a verdict on something that had not spoken yet.
    @Test func aHandshakeInFlightStillDefersToTheServer() {
        #expect(!route(server: .starting))
    }

    @Test func aHandshakeThatNeverFinishesStopsBlockingPrettier() {
        #expect(route(server: .starting, timedOut: true))
    }

    /// Waiting is for the reader who pressed a key, never for a save: format
    /// on save runs on every ⌘S, and stalling one on a restarting server would
    /// hold up a file the reader already has.
    @Test func onlyTheCommandWaitsForAHandshake() {
        #expect(EditorFormatRoute.waitsForServer(trigger: .command, server: .starting))
        #expect(!EditorFormatRoute.waitsForServer(trigger: .save, server: .starting))
    }

    /// And only while one is actually in flight — every other state is an
    /// answer already.
    @Test func aServerThatIsNotStartingIsNotWaitedFor() {
        #expect(!EditorFormatRoute.waitsForServer(trigger: .command, server: .running))
        #expect(!EditorFormatRoute.waitsForServer(trigger: .command, server: .notInstalled))
        #expect(!EditorFormatRoute.waitsForServer(trigger: .command, server: nil))
    }

    // MARK: The server that says yes and does nothing

    /// Shell is the case. `bash-language-server` advertises formatting and
    /// shells out to `shfmt`, so the tool defers to it — and a server that
    /// cannot find `shfmt` on its own `PATH` answers with an empty edit list
    /// while the tool sits installed and working. The reader gets a sentence
    /// about a server instead of a formatted file.
    @Test func aServerThatFormatsBlocksTheToolUntilItAnswersNothing() {
        #expect(!EditorFormatRoute.usesExternalFormatter(
            server: .running, serverFormats: true))

        #expect(EditorFormatRoute.usesExternalFormatter(
            server: .running, serverFormats: true, serverReturnedNothing: true))
    }

    /// The order is unchanged: a server that formats is still asked first, and
    /// the tool only follows a real answer.
    @Test func theToolStillGoesSecond() {
        #expect(EditorFormatRoute.usesExternalFormatter(
            server: .running, serverFormats: false))
        #expect(EditorFormatRoute.usesExternalFormatter(
            server: .notInstalled, serverFormats: false))
    }

    /// A handshake in flight is not an answer, so the tool waits — except
    /// after the server has been asked and returned nothing, which can only
    /// have happened because it did answer.
    @Test func aStartingServerStillHoldsTheTool() {
        #expect(!EditorFormatRoute.usesExternalFormatter(
            server: .starting, serverFormats: false))
        #expect(EditorFormatRoute.usesExternalFormatter(
            server: .starting, serverFormats: false, serverReturnedNothing: true))
    }
}
