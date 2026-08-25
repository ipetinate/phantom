import Foundation
@testable import Ghostty
import Testing

/// The editor grid's layout model.
///
/// Written against the two invariants the tree exists to hold, because those
/// are what a caller cannot see for itself: exactly one cell hosts the
/// terminal, and there is never a vacant cell. The plumbing — finding a
/// leaf, walking a split — is only interesting where it can break one of
/// those.
struct EditorGroupTreeTests {
    private func group(_ paths: [String], hostsTerminal: Bool = false) -> EditorGroup {
        var tabs = EditorTabSet()
        for path in paths { tabs.open(path) }
        if hostsTerminal { tabs.selectTerminal() }
        return EditorGroup(tabs: tabs, hostsTerminal: hostsTerminal)
    }

    /// The floor: one cell, holding the terminal, is a whole grid.
    private func singleCell() -> EditorGroupTree {
        .leaf(group([], hostsTerminal: true))
    }

    // MARK: Splitting

    @Test func splittingACellProducesTwoInLayoutOrder() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let arriving = group(["/a.ts"])

        let didSplit = tree.split(host, direction: .horizontal, inserting: arriving)
        #expect(didSplit)
        #expect(tree.groupIDs == [host, arriving.id])
    }

    /// A drop on the leading or top edge puts the arriving cell first, which
    /// is the difference between "beside" and "before".
    @Test func splittingOnTheFirstSidePutsTheNewCellFirst() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let arriving = group(["/a.ts"])

        tree.split(host, direction: .vertical, inserting: arriving, onFirstSide: true)

        #expect(tree.groupIDs == [arriving.id, host])
    }

    @Test func splittingAnUnknownCellChangesNothing() {
        var tree = singleCell()
        let before = tree

        let didSplit = tree.split(UUID(), direction: .horizontal, inserting: group(["/a.ts"]))
        #expect(!didSplit)
        #expect(tree == before)
    }

    /// Nesting is how 2x2 and 3x3 are reached, so a split of a split has to
    /// land in the right half.
    @Test func aCellInsideASplitCanSplitAgain() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let second = group(["/a.ts"])
        tree.split(host, direction: .horizontal, inserting: second)
        let third = group(["/b.ts"])

        tree.split(second.id, direction: .vertical, inserting: third)

        #expect(tree.groupIDs == [host, second.id, third.id])
        #expect(tree.groups.count == 3)
    }

    // MARK: Removing

    @Test func removingACellGivesItsSpaceToTheSibling() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let arriving = group(["/a.ts"])
        tree.split(host, direction: .horizontal, inserting: arriving)

        let didRemove = tree.remove(arriving.id)
        #expect(didRemove)
        #expect(tree.groupIDs == [host])
    }

    /// The grid always has a cell, so the last one cannot be removed — there
    /// would be nothing to put in its place.
    @Test func theLastCellIsNeverRemoved() {
        var tree = singleCell()
        let host = tree.groupIDs[0]

        let didRemove = tree.remove(host)
        #expect(!didRemove)
        #expect(tree.groupIDs == [host])
    }

    /// Invariant 1, the expensive half: removing the terminal's cell must
    /// not take the terminal with it, or there is no way back to the shell.
    @Test func removingTheTerminalsCellHandsTheTerminalToTheSurvivor() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let files = group(["/a.ts"])
        tree.split(host, direction: .horizontal, inserting: files)

        tree.remove(host)

        #expect(tree.groupIDs == [files.id])
        #expect(tree.terminalHost == files.id)
        #expect(tree.groups.count(where: \.hostsTerminal) == 1)
    }

    /// The cell that adopts the terminal keeps showing what it was showing:
    /// closing a split is not a request to look at the shell.
    @Test func adoptingTheTerminalDoesNotChangeWhatTheCellShows() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let files = group(["/a.ts"])
        tree.split(host, direction: .horizontal, inserting: files)

        tree.remove(host)

        #expect(tree.group(files.id)?.tabs.selectedPath == "/a.ts")
    }

    // MARK: Vacancy — invariant 2

    /// Closing the last file in a cell closes the cell, which is what makes
    /// a split feel like something you can undo.
    @Test func aCellThatRunsOutOfFilesIsRemoved() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let files = group(["/a.ts"])
        tree.split(host, direction: .horizontal, inserting: files)

        tree.close("/a.ts", in: files.id)

        #expect(tree.groupIDs == [host])
        #expect(tree.terminalHost == host)
    }

    /// The terminal's cell is not vacant with no files open — the terminal
    /// itself is what it is showing.
    @Test func theTerminalsCellSurvivesWithNoFiles() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        tree.update(host) { $0.tabs.open("/a.ts") }

        tree.close("/a.ts", in: host)

        #expect(tree.groupIDs == [host])
        #expect(tree.group(host)?.tabs.showsTerminal == true)
    }

    // MARK: Moving the terminal

    @Test func movingTheTerminalLeavesExactlyOneHost() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let files = group(["/a.ts"])
        tree.split(host, direction: .horizontal, inserting: files)
        tree.update(host) { $0.tabs.open("/b.ts") }

        tree.moveTerminal(to: files.id)

        #expect(tree.groups.count(where: \.hostsTerminal) == 1)
        #expect(tree.terminalHost == files.id)
    }

    /// The cell it lands in shows it: dragging the terminal somewhere is a
    /// request to see it there.
    @Test func theTerminalIsShownWhereItLands() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let files = group(["/a.ts"])
        tree.split(host, direction: .horizontal, inserting: files)
        tree.update(host) { $0.tabs.open("/b.ts") }

        tree.moveTerminal(to: files.id)

        #expect(tree.group(files.id)?.tabs.showsTerminal == true)
        #expect(tree.group(host)?.tabs.selectedPath == "/b.ts")
    }

    /// A cell that was only ever the terminal's frame goes away when the
    /// terminal leaves it.
    @Test func theCellTheTerminalLeavesCollapsesWhenItHeldNothingElse() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let files = group(["/a.ts"])
        tree.split(host, direction: .horizontal, inserting: files)

        tree.moveTerminal(to: files.id)

        #expect(tree.groupIDs == [files.id])
        #expect(tree.terminalHost == files.id)
    }

    @Test func movingTheTerminalToItsOwnCellChangesNothing() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let before = tree

        tree.moveTerminal(to: host)

        #expect(tree == before)
    }

    // MARK: Opening and moving files

    /// A file already open elsewhere is revealed there rather than opened
    /// twice — the rule `EditorTabSet` chose for one bar, applied to a grid.
    @Test func openingAFileAlreadyOpenElsewhereRevealsThatCell() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let files = group(["/a.ts", "/b.ts"])
        tree.split(host, direction: .horizontal, inserting: files)
        tree.update(files.id) { $0.tabs.select("/b.ts") }

        let landed = tree.open("/a.ts", in: host)

        #expect(landed == files.id)
        #expect(tree.group(files.id)?.tabs.selectedPath == "/a.ts")
        #expect(tree.group(host)?.tabs.tabs.isEmpty == true)
    }

    @Test func openingANewFileLandsInTheGivenCell() {
        var tree = singleCell()
        let host = tree.groupIDs[0]

        let landed = tree.open("/a.ts", in: host)

        #expect(landed == host)
        #expect(tree.group(host)?.tabs.selectedPath == "/a.ts")
    }

    @Test func movingAFileCollapsesTheCellItEmptied() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let files = group(["/a.ts"])
        tree.split(host, direction: .horizontal, inserting: files)

        tree.move("/a.ts", to: host)

        #expect(tree.groupIDs == [host])
        #expect(tree.group(host)?.tabs.selectedPath == "/a.ts")
    }

    @Test func movingAFileLeavesItsOtherTabsBehind() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let files = group(["/a.ts", "/b.ts"])
        tree.split(host, direction: .horizontal, inserting: files)

        tree.move("/a.ts", to: host)

        #expect(tree.groupIDs == [host, files.id])
        #expect(tree.group(files.id)?.holds("/a.ts") == false)
        #expect(tree.group(files.id)?.holds("/b.ts") == true)
        #expect(tree.group(host)?.holds("/a.ts") == true)
    }

    /// The pin belongs to the tab, so it crosses the grid with it — and lands
    /// the tab at the head of the bar it arrives in. Moving used to close the
    /// path here and open it there, which built a fresh tab at the far end
    /// and dropped both the pin and the dirty dot.
    @Test func aPinnedTabArrivesPinnedAndAtTheHead() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let files = group(["/a.ts", "/b.ts"])
        tree.split(host, direction: .horizontal, inserting: files)
        tree.update(files.id) { $0.tabs.setPinned(true, for: "/b.ts") }
        tree.update(host) { $0.tabs.open("/kept.ts") }

        tree.move("/b.ts", to: host)

        #expect(tree.group(host)?.tabs.tabs.map(\.path) == ["/b.ts", "/kept.ts"])
        #expect(tree.group(host)?.tabs.tab(for: "/b.ts")?.isPinned == true)
    }

    // MARK: Focus and dividers

    @Test func theNeighbourIsTheCellAcrossTheSplit() {
        var tree = singleCell()
        let host = tree.groupIDs[0]
        let files = group(["/a.ts"])
        tree.split(host, direction: .horizontal, inserting: files)

        #expect(tree.neighbour(of: host) == files.id)
        #expect(tree.neighbour(of: files.id) == host)
    }

    @Test func aLoneCellHasNoNeighbour() {
        let tree = singleCell()
        #expect(tree.neighbour(of: tree.groupIDs[0]) == nil)
    }

    @Test func aDividerMovesByItsOwnID() {
        var tree = singleCell()
        tree.split(tree.groupIDs[0], direction: .horizontal, inserting: group(["/a.ts"]))
        guard case .split(let split) = tree else {
            Issue.record("expected a split")
            return
        }

        tree.setRatio(0.3, forSplit: split.id)

        guard case .split(let moved) = tree else {
            Issue.record("expected a split")
            return
        }
        #expect(moved.ratio == 0.3)
        #expect(moved.id == split.id)
    }

    /// A divider dragged to the edge would leave a sliver no drag could
    /// recover, so the ratio is held away from the ends.
    @Test func aDividerCannotBeDraggedOffTheEdge() {
        var tree = singleCell()
        tree.split(tree.groupIDs[0], direction: .horizontal, inserting: group(["/a.ts"]))
        guard case .split(let split) = tree else {
            Issue.record("expected a split")
            return
        }

        tree.setRatio(0, forSplit: split.id)
        guard case .split(let low) = tree else { return }
        #expect(low.ratio >= 0.1)

        tree.setRatio(1, forSplit: split.id)
        guard case .split(let high) = tree else { return }
        #expect(high.ratio <= 0.9)
    }
}

/// Where a dragged tab lands, which is a question about a point in a
/// rectangle and nothing else.
struct EditorDropZoneTests {
    private let size = CGSize(width: 400, height: 200)

    /// The surface divides everywhere, and that is the point of it.
    ///
    /// An undivided cell has two useful answers — side by side or stacked —
    /// so the whole surface says which, and the four edges meet along the
    /// cell's diagonals. Aiming near a border is what the reader reported as
    /// the gesture being hard to hit.
    @Test func theSurfaceSplitsEverywhere() {
        for x in stride(from: 5.0, through: 395.0, by: 15.0) {
            for y in stride(from: 5.0, through: 195.0, by: 15.0) {
                let zone = EditorDropZone.resolve(point: CGPoint(x: x, y: y), in: size)
                #expect(zone != .center, "\(Int(x)),\(Int(y)) still means move")
            }
        }
    }

    /// Where the old middle third was, a drop now divides.
    @Test func theOldMiddleNowDivides() {
        #expect(EditorDropZone.resolve(point: CGPoint(x: 150, y: 100), in: size) == .leading)
        #expect(EditorDropZone.resolve(point: CGPoint(x: 250, y: 100), in: size) == .trailing)
        #expect(EditorDropZone.resolve(point: CGPoint(x: 200, y: 60), in: size) == .top)
        #expect(EditorDropZone.resolve(point: CGPoint(x: 200, y: 140), in: size) == .bottom)
    }

    /// Coordinates are y-down, as SwiftUI reports them: a small y is the top
    /// edge. Inverting this silently would split the wrong way, which is why
    /// it is asserted rather than assumed.
    @Test func theEdgesResolveWithYPointingDown() {
        #expect(EditorDropZone.resolve(point: CGPoint(x: 10, y: 100), in: size) == .leading)
        #expect(EditorDropZone.resolve(point: CGPoint(x: 390, y: 100), in: size) == .trailing)
        #expect(EditorDropZone.resolve(point: CGPoint(x: 200, y: 5), in: size) == .top)
        #expect(EditorDropZone.resolve(point: CGPoint(x: 200, y: 195), in: size) == .bottom)
    }

    /// A corner belongs to the nearer edge: four edges are what a split can
    /// express.
    @Test func aCornerGoesToTheNearerEdge() {
        #expect(EditorDropZone.resolve(point: CGPoint(x: 4, y: 20), in: size) == .leading)
        #expect(EditorDropZone.resolve(point: CGPoint(x: 40, y: 2), in: size) == .top)
    }

    /// The band is half of each axis, which is as much as there is: the four
    /// edges tile the surface and the centre is unreachable through it. It
    /// lives on the tab bar instead — see `aDropOnTheBarMeansMoveHere`.
    @Test func theBandIsHalfOfTheAxis() {
        #expect(EditorDropZone.defaultEdgeFraction == 0.5)
    }

    /// A narrower band still works, and the centre with it. The parameter is
    /// what the whole rule is expressed in, so a change to the default must
    /// not quietly turn the other values into dead code.
    @Test func aNarrowerBandBringsTheCentreBack() {
        let narrow: CGFloat = 0.25
        #expect(
            EditorDropZone.resolve(
                point: CGPoint(x: 200, y: 100), in: size, edgeFraction: narrow) == .center)
        #expect(
            EditorDropZone.resolve(
                point: CGPoint(x: 20, y: 100), in: size, edgeFraction: narrow) == .leading)
    }

    /// A zone already in hand wins against one that has only just overtaken
    /// it. Without that the answer flips as the pointer travels along a
    /// diagonal — split left, split up, split left — and the panel flickers
    /// under the cursor while the reader is aiming at it.
    @Test func aZoneInHandHoldsPastTheDiagonal() {
        /// Just past the diagonal: `leading` is 0.30 of the way in, `top` is
        /// 0.32, so the nearest edge has changed hands by 0.02.
        let justPast = CGPoint(x: 120, y: 64)

        #expect(EditorDropZone.resolve(point: justPast, in: size) == .leading)
        #expect(
            EditorDropZone.resolve(point: justPast, in: size, current: .top) == .top)
    }

    /// Hysteresis holds a boundary, it does not move it arbitrarily far: past
    /// the margin the new answer wins even against a zone in hand.
    @Test func hysteresisRunsOutEventually() {
        /// `leading` at 0.20 against `top` at 0.40 — a fifth of the cell
        /// apart, which is far outside the margin.
        #expect(
            EditorDropZone.resolve(
                point: CGPoint(x: 80, y: 80), in: size, current: .top) == .leading)
    }

    /// A cell with no size yet cannot be split into halves, so it answers
    /// the harmless thing.
    @Test func aCellWithNoSizeMeansTheCentre() {
        #expect(EditorDropZone.resolve(point: .zero, in: .zero) == .center)
    }

    @Test func aPointOutsideTheCellIsClampedIntoIt() {
        #expect(EditorDropZone.resolve(point: CGPoint(x: -50, y: 100), in: size) == .leading)
        #expect(EditorDropZone.resolve(point: CGPoint(x: 900, y: 100), in: size) == .trailing)
    }

    // MARK: The bar is a join

    /// The bug this rule exists for, pinned: a drag starts on a tab, so it
    /// starts at the top of a cell and arrives at the top of the next one.
    /// With the bar resolving like any other top edge, taking a tab back
    /// split the grid into rows instead of merging it — every time, which is
    /// how it was reported.
    @Test func aDropOnTheBarMeansMoveHere() {
        let bar: CGFloat = 39
        #expect(
            EditorDropZone.resolve(
                point: CGPoint(x: 200, y: 10), in: size, barHeight: bar) == .center)
        #expect(
            EditorDropZone.resolve(
                point: CGPoint(x: 20, y: 30), in: size, barHeight: bar) == .center)
    }

    /// Below the bar the edges still divide, measured against the surface
    /// rather than against the whole cell — otherwise the band would sit a
    /// bar's height off.
    @Test func theSurfacesEdgesStillSplit() {
        let bar: CGFloat = 39
        let surfaceHeight = size.height - bar

        #expect(
            EditorDropZone.resolve(
                point: CGPoint(x: 200, y: bar + surfaceHeight * 0.05),
                in: size, barHeight: bar) == .top)
        #expect(
            EditorDropZone.resolve(
                point: CGPoint(x: 200, y: bar + surfaceHeight * 0.95),
                in: size, barHeight: bar) == .bottom)
        #expect(
            EditorDropZone.resolve(
                point: CGPoint(x: 10, y: bar + surfaceHeight * 0.5),
                in: size, barHeight: bar) == .leading)
    }

    /// A cell with no bar has no strip to aim at, so the plain geometry
    /// applies and the top edge is a top edge again.
    @Test func withNoBarTheTopEdgeIsAnEdge() {
        #expect(
            EditorDropZone.resolve(
                point: CGPoint(x: 200, y: 5), in: size, barHeight: 0) == .top)
    }

    @Test func onlyTheCentreAsksForNoSplit() {
        #expect(EditorDropZone.center.split == nil)
        #expect(EditorDropZone.leading.split?.onFirstSide == true)
        #expect(EditorDropZone.trailing.split?.direction == .horizontal)
        #expect(EditorDropZone.top.split?.direction == .vertical)
        #expect(EditorDropZone.bottom.split?.onFirstSide == false)
    }
}

/// The highlight's own state, which is a reference type for a measured
/// reason — see `EditorCellDropState`.
@MainActor
struct EditorCellDropStateTests {
    @Test func showingTheSameZoneTwiceIsOneChange() {
        let state = EditorCellDropState(session: EditorTabDragSession())
        state.show(.top)
        state.show(.top)
        #expect(state.zone == .top)
    }

    /// The reader takes a tab and drops it back on the cell it came from.
    /// That session ends with neither `performDrop` nor `dropExited` reaching
    /// this cell, and the panel used to stay painted over the pane for good.
    ///
    /// The session reports the ending, so the state hears it there rather
    /// than inferring it from the mouse button.
    @Test func aPanelCannotOutliveItsSession() {
        let session = EditorTabDragSession()
        let state = EditorCellDropState(session: session)

        session.begin(.terminal)
        state.show(.bottom)
        #expect(state.zone == .bottom)

        session.end()
        #expect(state.zone == nil, "a highlight outlived the drag behind it")
    }

    @Test func clearingItLeavesNothingToClear() {
        let state = EditorCellDropState(session: EditorTabDragSession())
        state.show(.leading)
        state.show(nil)
        #expect(state.zone == nil)
    }

    /// Two cells watch the same session, and one ending clears both — no cell
    /// can be left lit because the drag happened to end over its neighbour.
    @Test func everyCellHearsTheSameEnding() {
        let session = EditorTabDragSession()
        let first = EditorCellDropState(session: session)
        let second = EditorCellDropState(session: session)

        session.begin(.file("/tmp/a.swift"))
        first.show(.leading)
        second.show(.trailing)

        session.end()
        #expect(first.zone == nil)
        #expect(second.zone == nil)
    }
}
