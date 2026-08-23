import Foundation
@testable import Ghostty
import Testing

/// How `EditorCenter` routes the grid's gestures.
///
/// The model's own rules are in `EditorGroupTreeTests`; these are the
/// decisions the centre makes on top of it — which cell a file opens in, what
/// a drop does, where focus goes when a cell collapses under it, and the two
/// facts the AppKit host reads instead of the tree.
///
/// Written against the gestures rather than against the tree, because the
/// tree is the centre's own state: a test that reached past `drop` and
/// `focus` to arrange a layout by hand would be asserting about a shape the
/// app has no way to reach.
@MainActor
struct EditorGroupRoutingTests {
    /// A real file, because `EditorCenter.open` loads one from disk.
    private func file(_ contents: String = "let a = 1") -> String {
        let path = NSTemporaryDirectory() + "phantom-grid-\(UUID().uuidString).swift"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func remove(_ paths: String...) {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
    }

    /// Two files open, the second dragged out into a cell of its own — the
    /// arrangement most of these tests start from.
    private struct Split {
        let center: EditorCenter
        let first: String
        let second: String
        let host: EditorGroup.ID
        let other: EditorGroup.ID
    }

    private func splitCentre() -> Split {
        let center = EditorCenter()
        let host = center.activeGroupID
        let first = file()
        let second = file()
        _ = center.open(URL(fileURLWithPath: first))
        _ = center.open(URL(fileURLWithPath: second))

        center.drop(.file(second), on: host, zone: .trailing)
        return Split(
            center: center, first: first, second: second,
            host: host, other: center.activeGroupID)
    }

    /// A fresh centre is one cell holding the terminal — the shape the pane
    /// always had, now said out loud.
    @Test func aFreshCentreIsOneCellHoldingTheTerminal() {
        let center = EditorCenter()

        #expect(center.tree.groups.count == 1)
        #expect(center.tree.terminalHost == center.activeGroupID)
        #expect(center.paneVisibility.showsTerminal)
        #expect(!center.paneVisibility.showsTabBar)
    }

    // MARK: Dropping

    /// Dragging a tab to an edge splits the cell and takes the tab with it.
    @Test func droppingOnAnEdgeSplitsAndCarriesTheTab() {
        let split = splitCentre()
        let (center, first, second, host, other) =
            (split.center, split.first, split.second, split.host, split.other)
        defer { remove(first, second) }

        #expect(center.tree.groups.count == 2)
        #expect(other != host)
        #expect(center.tree.group(other)?.holds(second) == true)
        #expect(center.tree.group(host)?.holds(second) == false)
        #expect(center.tree.group(host)?.holds(first) == true)
    }

    /// The cell it lands in takes focus: you dragged it there to work on it.
    @Test func aDroppedTabTakesFocus() {
        let split = splitCentre()
        let (center, first, second, other) =
            (split.center, split.first, split.second, split.other)
        defer { remove(first, second) }

        #expect(center.activeGroupID == other)
        #expect(center.tabs.selectedPath == second)
    }

    /// The centre of a cell means "move it here", with no new split.
    @Test func droppingOnTheCentreMovesWithoutSplitting() {
        let split = splitCentre()
        let (center, first, second, host, other) =
            (split.center, split.first, split.second, split.host, split.other)
        defer { remove(first, second) }

        center.drop(.file(second), on: host, zone: .center)

        #expect(center.tree.groups.count == 1)
        #expect(center.activeGroupID == host)
        #expect(center.tree.group(host)?.holds(second) == true)
        #expect(center.tree.group(other) == nil)
    }

    /// The terminal is draggable like any tab, which is the headline of the
    /// whole feature: a shell beside a file.
    @Test func theTerminalCanBeDraggedIntoItsOwnCell() {
        let center = EditorCenter()
        let host = center.activeGroupID
        let path = file()
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        center.drop(.terminal, on: host, zone: .bottom)

        #expect(center.tree.groups.count == 2)
        #expect(center.tree.terminalHost == center.activeGroupID)
        #expect(center.tree.terminalHost != host)
        #expect(center.tree.group(host)?.holds(path) == true)
        #expect(center.paneVisibility.showsTerminal)
    }

    /// The gesture the feature exists for, from the state the app starts in:
    /// one cell with the shell and a file in it, and the file dragged to an
    /// edge leaves the two side by side.
    @Test func draggingAFileOutOfTheTerminalsCellPutsThemSideBySide() {
        let center = EditorCenter()
        let host = center.activeGroupID
        let path = file()
        defer { remove(path) }
        _ = center.open(URL(fileURLWithPath: path))

        center.drop(.file(path), on: host, zone: .trailing)

        #expect(center.tree.groups.count == 2)
        #expect(center.tree.terminalHost == host)
        #expect(center.tree.group(host)?.tabs.isEmpty == true)
        #expect(center.tree.group(center.activeGroupID)?.holds(path) == true)
        #expect(center.activeGroupID != host)
    }

    /// A cell with nothing in it but the terminal cannot be split by the
    /// terminal: there would be nothing on the other side, so the layout
    /// ends where it began.
    @Test func droppingTheTerminalOnItsOwnEmptyCellChangesNothing() {
        let center = EditorCenter()

        center.drop(.terminal, on: center.activeGroupID, zone: .leading)

        #expect(center.tree.groups.count == 1)
        #expect(center.tree.terminalHost == center.activeGroupID)
        #expect(center.paneVisibility.showsTerminal)
    }

    /// Same rule for a file that is all its cell has: splitting it out would
    /// leave a hole, so the grid keeps the shape it had.
    @Test func droppingACellsOnlyFileOnItsOwnEdgeChangesNothing() {
        let split = splitCentre()
        let (center, first, second, host, other) =
            (split.center, split.first, split.second, split.host, split.other)
        defer { remove(first, second) }

        center.drop(.file(second), on: other, zone: .leading)

        #expect(center.tree.groups.count == 2)
        #expect(center.tree.group(host)?.holds(first) == true)
        #expect(center.tree.group(center.activeGroupID)?.holds(second) == true)
        #expect(center.activeGroupID != host)
    }

    /// A drop on a cell that has since gone away must not strand focus.
    @Test func droppingOnAnUnknownCellChangesNothing() {
        let center = EditorCenter()
        let before = center.tree

        center.drop(.terminal, on: UUID(), zone: .trailing)

        #expect(center.tree == before)
    }

    // MARK: Opening and focus

    /// The rule the feature turns on: a file opens where the reader is
    /// working.
    @Test func aFileOpensInTheCellInFocus() {
        let split = splitCentre()
        let (center, first, second, host, other) =
            (split.center, split.first, split.second, split.host, split.other)
        let third = file()
        defer { remove(first, second, third) }

        _ = center.open(URL(fileURLWithPath: third))

        #expect(center.activeGroupID == other)
        #expect(center.tree.group(other)?.holds(third) == true)
        #expect(center.tree.group(host)?.holds(third) == false)
    }

    /// A file already open in another cell is revealed there rather than
    /// opened twice — two live editors over one file would need a shared
    /// buffer to be honest about saving.
    @Test func openingAFileOpenElsewhereRevealsItInstead() {
        let split = splitCentre()
        let (center, first, second, host) =
            (split.center, split.first, split.second, split.host)
        defer { remove(first, second) }

        _ = center.open(URL(fileURLWithPath: first))

        #expect(center.activeGroupID == host)
        #expect(center.tree.groups.count(where: { $0.holds(first) }) == 1)
    }

    /// Selecting a tab in another cell is also a request to work in that
    /// cell.
    @Test func selectingATabInAnotherCellMovesFocusThere() {
        let split = splitCentre()
        let (center, first, second, host, other) =
            (split.center, split.first, split.second, split.host, split.other)
        defer { remove(first, second) }
        #expect(center.activeGroupID == other)

        center.select(first)

        #expect(center.activeGroupID == host)
        #expect(center.tabs.selectedPath == first)
    }

    /// Closing the last file in a cell closes the cell, and focus lands on
    /// the sibling that took its space rather than on nothing.
    @Test func focusFallsToTheSiblingWhenACellCollapses() {
        let split = splitCentre()
        let (center, first, second, host) =
            (split.center, split.first, split.second, split.host)
        defer { remove(first, second) }

        center.close(second)

        #expect(center.tree.groups.count == 1)
        #expect(center.activeGroupID == host)
        #expect(center.tabs.selectedPath == first)
    }

    /// The terminal stays reachable from anywhere: asking for it moves focus
    /// to the cell it lives in.
    @Test func showingTheTerminalFocusesItsCell() {
        let split = splitCentre()
        let (center, first, second, host, other) =
            (split.center, split.first, split.second, split.host, split.other)
        defer { remove(first, second) }
        #expect(center.activeGroupID == other)

        center.selectTerminal()

        #expect(center.activeGroupID == host)
        #expect(center.paneVisibility.showsTerminal)
    }

    /// Closing a cell takes its files with it, through the same close every
    /// tab uses — so a language server still hears about them.
    @Test func closingACellClosesItsFiles() {
        let split = splitCentre()
        let (center, first, second, host, other) =
            (split.center, split.first, split.second, split.host, split.other)
        defer { remove(first, second) }

        center.closeCell(other)

        #expect(center.tree.groups.count == 1)
        #expect(center.activeGroupID == host)
        #expect(center.documents[second] == nil)
        #expect(center.documents[first] != nil)
    }

    // MARK: Facts the host reads

    /// The host switches views on `paneVisibility`, so it has to follow the
    /// cell in focus and not the grid at large.
    @Test func paneVisibilityFollowsTheCellInFocus() {
        let split = splitCentre()
        let (center, first, second, host, other) =
            (split.center, split.first, split.second, split.host, split.other)
        defer { remove(first, second) }

        #expect(!center.paneVisibility.showsTerminal)
        #expect(center.paneVisibility.showsTabBar)

        center.focus(host)
        center.selectTerminal()
        #expect(center.paneVisibility.showsTerminal)

        center.focus(other)
        #expect(!center.paneVisibility.showsTerminal)
    }

    /// The migration plan is about every open file: a dirty one in another
    /// cell is exactly the one a worktree switch must not leave behind
    /// quietly.
    @Test func theMigrationPlanSeesEveryCell() {
        let split = splitCentre()
        let (center, first, second) = (split.center, split.first, split.second)
        defer { remove(first, second) }

        let planned = center.openForMigration.map(\.path)

        #expect(planned.contains(first))
        #expect(planned.contains(second))
    }

    /// Closing everything returns the grid to its floor: one cell, the
    /// terminal's.
    @Test func closingEverythingCollapsesTheGrid() {
        let split = splitCentre()
        let (center, first, second, host) =
            (split.center, split.first, split.second, split.host)
        defer { remove(first, second) }

        center.closeAll()

        #expect(center.tree.groups.count == 1)
        #expect(center.activeGroupID == host)
        #expect(center.paneVisibility.showsTerminal)
    }

    /// The dirty dot belongs to the tab, wherever that tab is: routed to the
    /// cell in focus it would mark the wrong tab, or none. The hop is the
    /// document's own — `objectWillChange` fires before the value is written,
    /// so the centre reads it a turn later.
    @Test func theDirtyDotLandsOnTheCellHoldingTheFile() async throws {
        let split = splitCentre()
        let (center, first, second, host, other) =
            (split.center, split.first, split.second, split.host, split.other)
        defer { remove(first, second) }
        #expect(center.activeGroupID == other)

        center.documents[first]?.edited("let a = 2")
        try await Task.sleep(for: .milliseconds(60))

        #expect(center.tree.group(host)?.tabs.tabs.first?.isDirty == true)
        #expect(center.tree.group(other)?.tabs.tabs.first?.isDirty == false)
    }
}
