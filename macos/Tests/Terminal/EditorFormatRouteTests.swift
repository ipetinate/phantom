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
        formats: Bool = false
    ) -> Bool {
        EditorFormatRoute.usesPrettierFromPath(
            trigger: trigger,
            prettierKnowsTheFile: knows,
            server: server,
            serverFormats: formats)
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
}
