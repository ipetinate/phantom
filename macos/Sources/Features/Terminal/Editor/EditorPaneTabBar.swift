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
                    onCommand: perform,
                    availability: { center.availability(of: .file($0.path)) },
                    terminalAvailability: center.availability(of: .terminal),
                    onTerminalCommand: performOnTerminal,
                    terminalTitle: center.terminalTitle,
                    onSelectTerminal: { center.selectTerminal() },
                    hostsTerminal: center.hostsTerminal(groupID),
                    reviews: cell.reviews,
                    onSelectReview: { center.selectReview($0.id) },
                    onCloseReview: { center.closeReview($0.id) },
                    onReorder: reorder
                )
                Divider()
            }
        }
    }

    private var cell: EditorTabSet { center.tabs(in: groupID) }

    /// Runs one of the tab menu's commands, against *this* cell.
    ///
    /// Closing is asked of the cell rather than of the window: a bar belongs
    /// to one cell, and "Close All" on a grid means the cell whose menu the
    /// reader opened, not every file on screen.
    private func perform(_ command: EditorTabCommand, on tab: EditorTab) {
        switch command {
        case .close:
            center.requestClose(tab.path)
        case .closeOthers:
            center.closeOthers(of: tab.path, in: groupID)
        case .closeAll:
            center.closeAll(in: groupID)
        case .pin:
            center.setPinned(true, for: tab.path)
        case .unpin:
            center.setPinned(false, for: tab.path)
        case .moveLeft:
            center.moveTab(tab.path, by: -1)
        case .moveRight:
            center.moveTab(tab.path, by: 1)
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tab.path)])
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.path, forType: .string)
        case .splitLeading, .splitTrailing, .splitTop, .splitBottom:
            guard let zone = command.zone else { return }
            center.splitOut(.file(tab.path), zone: zone)
        case .moveToMainPane:
            center.moveToMainPane(.file(tab.path))
        }
    }

    /// The terminal's menu offers the splits only, so nothing else can arrive
    /// here — and a command that did would be one this tab must not run.
    private func performOnTerminal(_ command: EditorTabCommand) {
        guard let zone = command.zone else { return }
        center.splitOut(.terminal, zone: zone)
    }

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

    /// Moves a tab along this cell's bar, and answers how many places it
    /// actually moved.
    ///
    /// Asked rather than assumed, because the strip refuses a move that would
    /// carry a tab out of its own run — the same rule the menu's Move Left and
    /// Move Right follow. A gesture that counted a refused move would drift
    /// out of step with the bar, and dragging back to where it began would
    /// then displace a tab that had never moved.
    ///
    /// **One place at a time, rather than asking for the whole distance.**
    /// `EditorTabSet.canMove(_:by:)` answers about the destination, so it
    /// refuses a run of places wholesale when only the far end of it is out
    /// of bounds. A slow drag never notices — its events arrive one place
    /// apart — but a flick arrives as a single jump of several, and asking
    /// for all of them at once would pin the tab in place for the rest of the
    /// gesture instead of carrying it as far as it can go. Walking the run
    /// stops it at the boundary, which is what a reader dragging a tab into
    /// the pinned run expects to see.
    private func reorder(_ tab: EditorTab, by places: Int) -> Int {
        guard places != 0 else { return 0 }

        let step = places > 0 ? 1 : -1
        var moved = 0
        while moved != places, cell.canMove(tab.path, by: step) {
            center.moveTab(tab.path, by: step)
            moved += step
        }
        return moved
    }
}
