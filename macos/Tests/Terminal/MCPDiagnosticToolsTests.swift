import Foundation
@testable import Ghostty
import Testing

/// The diagnostic half of the MCP server.
///
/// Scope worth stating: `LSPCenter.shared.diagnostics` is `private(set)` on a
/// singleton, so the language-server path cannot be seeded from here and is
/// not asserted end to end. What is covered is everything that decides the
/// *answer* — the containment rule that gates consent, the severity
/// threshold, the formatter's own store, and the surface itself.
@MainActor
struct MCPDiagnosticToolsTests {
    // MARK: What is on offer

    @Test func theToolsAreTheTwoDiagnosticOnes() {
        let names = MCPDiagnosticTools.all.map(\.tool.name)
        #expect(names == ["list_diagnostics", "list_language_servers"])
    }

    @Test func theyReachTheClientThroughTheRegistry() {
        let registered = Set(MCPToolRegistry.all.map(\.tool.name))
        for handler in MCPDiagnosticTools.all {
            #expect(registered.contains(handler.tool.name))
        }
    }

    /// Neither takes anything it cannot do without: a call with no arguments
    /// is the one an agent makes to orient itself.
    @Test func neitherToolRequiresAnArgument() {
        for handler in MCPDiagnosticTools.all {
            let required = handler.tool.schema.object?["required"]?.array
            #expect(required == nil || required == [])
        }
    }

    @Test func everyDescriptionSaysWhenToReachForIt() {
        for handler in MCPDiagnosticTools.all {
            #expect(handler.tool.description.contains("Use it"))
        }
    }

    /// One-based is promised in the description because an off-by-one line
    /// number is a wrong answer that reads like a right one.
    @Test func theDiagnosticsToolPromisesOneBasedLines() {
        let handler = MCPDiagnosticTools.all.first { $0.tool.name == "list_diagnostics" }!
        #expect(handler.tool.description.contains("one-based"))
    }

    // MARK: The containment rule that gates consent

    /// The reason this is compared by component and not by string prefix.
    /// `/a/bc` has `/a/b` as a string prefix and is a different project, and
    /// getting it wrong hands out its diagnostics without ever asking.
    @Test func aSiblingDirectoryIsNotInsideTheProject() {
        #expect(MCPDiagnosticTools.isInside("/a/bc/x.swift", root: "/a/b") == false)
        #expect(MCPDiagnosticTools.isInside("/a/b-other/x.swift", root: "/a/b") == false)
    }

    @Test func aFileUnderTheRootIsInside() {
        #expect(MCPDiagnosticTools.isInside("/a/b/x.swift", root: "/a/b"))
        #expect(MCPDiagnosticTools.isInside("/a/b/deep/x.swift", root: "/a/b"))
    }

    @Test func aFileAboveTheRootIsNotInside() {
        #expect(MCPDiagnosticTools.isInside("/a/x.swift", root: "/a/b") == false)
    }

    @Test func trailingSlashesAndDotsDoNotChangeTheAnswer() {
        #expect(MCPDiagnosticTools.isInside("/a/b/./x.swift", root: "/a/b/"))
    }

    // MARK: Severity as a word

    /// One is the most severe in the protocol, so "this bad or worse" is a
    /// single comparison and reads the right way round.
    @Test func aThresholdIncludesEverythingAsSevereOrWorse() {
        #expect(MCPDiagnosticTools.Severity.error.rank < MCPDiagnosticTools.Severity.warning.rank)
        #expect(MCPDiagnosticTools.Severity.hint.rank > MCPDiagnosticTools.Severity.information.rank)
    }

    @Test func everyProtocolSeverityHasAWord() {
        #expect(MCPDiagnosticTools.Severity(.error) == .error)
        #expect(MCPDiagnosticTools.Severity(.warning) == .warning)
        #expect(MCPDiagnosticTools.Severity(.information) == .information)
        #expect(MCPDiagnosticTools.Severity(.hint) == .hint)
    }

    // MARK: The formatter's failure

    @Test func aFailureIsKeptAndReadBack() {
        let store = FormatFailureStore.shared
        let path = "/tmp/phantom-format-\(UUID().uuidString).vue"
        defer { store.clear(path) }

        store.record("Unexpected token at line 4", for: path)

        #expect(store.failure(for: path)?.message == "Unexpected token at line 4")
    }

    /// A fixed file that keeps reporting its old failure sends whoever reads
    /// it after a problem that is gone.
    @Test func aSuccessClearsIt() {
        let store = FormatFailureStore.shared
        let path = "/tmp/phantom-format-\(UUID().uuidString).vue"
        store.record("Unexpected token", for: path)

        store.clear(path)

        #expect(store.failure(for: path) == nil)
    }

    @Test func theNextFailureReplacesTheLast() {
        let store = FormatFailureStore.shared
        let path = "/tmp/phantom-format-\(UUID().uuidString).vue"
        defer { store.clear(path) }

        store.record("first", for: path)
        store.record("second", for: path)

        #expect(store.failure(for: path)?.message == "second")
    }
}
