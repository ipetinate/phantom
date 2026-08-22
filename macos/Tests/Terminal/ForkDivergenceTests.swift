import Foundation
@testable import Ghostty
import Testing

/// Upstream behaviours this fork deliberately changed, pinned by reading the
/// source that changed them.
///
/// The risk these guard against is specific to a fork: a merge from upstream
/// restores the file it owns, the deliberate change goes with it, and nothing
/// fails — because what was removed was *code*, and no test names code that is
/// supposed to be absent. Each case here was reported by hand first, so the
/// cost of losing it again is another round of screenshots.
///
/// Reading source is the established way to assert this in this project; see
/// `EditorEngineBoundaryTests`, which enforces the editor's import boundary the
/// same way. Kept to a handful: a test that reads source is only worth writing
/// where the thing it protects cannot be observed any other way.
struct ForkDivergenceTests {
    /// The file's code, with comments removed.
    ///
    /// Stripping them is not tidiness: each of these divergences is *explained*
    /// in a comment that names the thing it removed, so a scan over raw text
    /// finds the very words it is checking for and fails on its own
    /// documentation. `EditorEngineBoundaryTests` strips for the same reason.
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources").appendingPathComponent(path)
        let text = try String(contentsOf: url, encoding: .utf8)

        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Upstream draws a banner across the top of every window in a debug
    /// build. The titlebar already carries a DEV badge, and the banner takes a
    /// row from the terminal to say the same thing — so the view was deleted
    /// rather than hidden, and this is what keeps it deleted.
    @Test func theDebugBuildBannerStaysGone() throws {
        let terminalView = try source("Features/Terminal/TerminalView.swift")

        /// A control first. Every other assertion here is an *absence*, and an
        /// absence passes vacuously against an empty string — so the test
        /// proves it read the file it meant to before trusting what is not in
        /// it.
        #expect(terminalView.contains("TerminalSplitTreeView"))

        #expect(!terminalView.contains("DebugBuildWarningView"))
        #expect(!terminalView.contains("GHOSTTY_BUILD_MODE_DEBUG"))
    }

    /// The sidebar divider runs the full height of the window, titlebar strip
    /// included. It used to stop at `safeAreaInsets.top` to avoid stacking a
    /// second coat over the strip, and the gap that left in the line is what
    /// got reported — so the clip must not come back.
    @Test func theDividerIsNotClippedByTheTitlebar() throws {
        let layout = try source("Features/Terminal/Sidebar/SidebarLayoutModel.swift")
        let drawDivider = try #require(layout.range(of: "override func drawDivider"))
        let body = layout[drawDivider.lowerBound...].prefix(1200)

        #expect(!body.contains("safeAreaInsets"), "the divider is clipping again")
    }

    /// Writing to a language server's stdin is queued, never waited on. A
    /// `sync` here froze the whole window until the server drained its pipe —
    /// measured at thirty seconds against one that never reads.
    @Test func theLanguageServerWriteIsNeverSynchronous() throws {
        let process = try source("Features/Terminal/Editor/LSP/LSPProcess.swift")

        #expect(process.contains("writeQueue.async"))
        #expect(!process.contains("writeQueue.sync"))
    }
}
