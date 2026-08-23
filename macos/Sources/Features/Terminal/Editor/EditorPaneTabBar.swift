import SwiftUI

/// The pane's tab bar, above whichever surface is showing.
///
/// Rendered by **both** the terminal and the editor, from the same
/// `EditorCenter`. That looks like duplication and is the opposite: the bar
/// has to be present while the terminal is on screen — otherwise there is no
/// way back to a file — and the terminal and the editor are sibling AppKit
/// views with no shared SwiftUI parent to hang it on. One view, one state,
/// drawn by whichever half is visible; only ever one at a time.
///
/// Collapses to nothing when no file is open. With the terminal alone there
/// is nothing to switch to, so the bar would be a control that does nothing
/// while costing the terminal a row of its height to say so.
struct EditorPaneTabBar: View {
    @ObservedObject var center: EditorCenter

    /// The cell this bar belongs to. Every question it asks is about that
    /// cell, not about the one in focus.
    let groupID: EditorGroup.ID

    /// Where the terminal under this bar is, so a tab can be marked when it
    /// is showing a file from a checkout the terminal has left.
    @ObservedObject var terminalDirectory: EditorTerminalDirectory

    /// The open files that are in another worktree of the terminal's
    /// repository, by path.
    ///
    /// Resolved into state rather than asked per row while rendering. The
    /// answer costs a walk up to `.git` and a couple of small reads *per
    /// tab*, and this bar redraws for reasons that have nothing to do with
    /// worktrees — the shell rewriting the window title is enough, which
    /// during a build is several times a second. Recomputed on the only two
    /// things that can change it: the terminal moving, and the set of open
    /// tabs.
    @State private var divergent: Set<String> = []

    var body: some View {
        content
            .onAppear(perform: resolveDivergence)
            .onChange(of: terminalDirectory.path) { _ in resolveDivergence() }
            .onChange(of: center.tabs(in: groupID)) { _ in resolveDivergence() }
            // Always full width, never an opinion about it.
            //
            // With no file open the body below is *empty*, and an
            // `NSHostingView` wrapping empty SwiftUI reports an intrinsic
            // width of nothing. Pinned to both sides of the pane, that made
            // the hosting view dictate the pane's width instead of following
            // it: the window opened narrow and refused to grow sideways —
            // double-clicking the titlebar only made it taller.
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if showsBar {
            VStack(spacing: 0) {
                EditorTabBar(
                    tabs: cell.tabs,
                    selection: cell.selection,
                    needsDirectory: { cell.needsDirectory(for: $0) },
                    isDivergent: { divergent.contains($0.path) },
                    onSelect: { center.select($0) },
                    onClose: { center.requestClose($0) },
                    terminalTitle: center.terminalTitle,
                    onSelectTerminal: { center.selectTerminal() },
                    hostsTerminal: center.hostsTerminal(groupID)
                )
                Divider()
            }
        }
    }

    private var cell: EditorTabSet { center.tabs(in: groupID) }

    /// See `EditorCenter.showsTabBar(in:)`, which is where the rule lives so
    /// the drop can read the same answer.
    private var showsBar: Bool { center.showsTabBar(in: groupID) }

    private func resolveDivergence() {
        let directory = terminalDirectory.path
        divergent = Set(
            cell.tabs
                .map(\.path)
                .filter {
                    WorktreeDivergence.verdict(
                        documentPath: $0, terminalDirectory: directory) != nil
                })
    }
}
