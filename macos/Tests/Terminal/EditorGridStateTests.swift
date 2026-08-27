import Foundation
@testable import Ghostty
import Testing

/// The editor grid's persistence.
///
/// Written against the three things a reader would notice missing after a
/// relaunch — which files are open, where they sit, and which one each cell
/// was showing — and against the one rule that makes a restore safe to
/// attempt at all: a file that is gone costs its own tab and nothing else.
struct EditorGridStateTests {
    private func group(
        _ paths: [String],
        pinned: [String] = [],
        selected: String? = nil,
        hostsTerminal: Bool = false
    ) -> EditorGroup {
        var tabs = EditorTabSet()
        for path in paths { tabs.open(path) }
        for path in pinned { tabs.setPinned(true, for: path) }
        if let selected {
            tabs.select(selected)
        } else if hostsTerminal {
            tabs.selectTerminal()
        }
        return EditorGroup(tabs: tabs, hostsTerminal: hostsTerminal)
    }

    /// Everything named here is on disk, which is the ordinary case.
    private func allOpen(_ path: String) -> Bool { true }

    private func roundTrip(_ state: EditorGridState) throws -> EditorGridState {
        let data = try JSONEncoder().encode(state)
        return try JSONDecoder().decode(EditorGridState.self, from: data)
    }

    // MARK: A grid with a split

    /// The shape is the point: a split has to survive as a split, with the
    /// side each cell was on and the divider where the reader left it.
    @Test func aGridWithASplitSurvivesEncodingAndDecoding() throws {
        let left = group(["/a.ts"], selected: "/a.ts", hostsTerminal: true)
        let right = group(["/b.ts", "/c.ts"], selected: "/c.ts")
        let tree = EditorGroupTree.split(.init(
            direction: .horizontal, ratio: 0.35, first: .leaf(left), second: .leaf(right)))

        let decoded = try roundTrip(EditorGridState(tree, activeGroupID: right.id))

        guard case .split(let split) = decoded.root else {
            Issue.record("a split was saved as something other than a split")
            return
        }
        #expect(split.direction == .horizontal)
        #expect(split.ratio == 0.35)
        #expect(split.first.cells.map(\.files) == [[.init(path: "/a.ts", isPinned: false)]])
        #expect(split.second.cells[0].files.map(\.path) == ["/b.ts", "/c.ts"])
    }

    /// The file the JSON is written to outlives the build that wrote it, so
    /// the key a split is stored under is part of the format.
    @Test func aSplitIsWrittenUnderASplitKey() throws {
        let tree = EditorGroupTree.split(.init(
            direction: .vertical,
            first: .leaf(group(["/a.ts"], hostsTerminal: true)),
            second: .leaf(group(["/b.ts"]))))

        let data = try JSONEncoder().encode(EditorGridState(tree, activeGroupID: tree.groupIDs[0]))
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"split\""))
        #expect(json.contains("\"cell\""))
    }

    @Test func nestedSplitsSurvive() throws {
        let inner = EditorGroupTree.split(.init(
            direction: .vertical,
            first: .leaf(group(["/b.ts"])),
            second: .leaf(group(["/c.ts"]))))
        let tree = EditorGroupTree.split(.init(
            direction: .horizontal,
            first: .leaf(group(["/a.ts"], hostsTerminal: true)),
            second: inner))

        let decoded = try roundTrip(EditorGridState(tree, activeGroupID: tree.groupIDs[0]))

        #expect(decoded.paths == ["/a.ts", "/b.ts", "/c.ts"])
        let rebuilt = try #require(decoded.rebuilt(isOpen: allOpen))
        #expect(rebuilt.tree.groups.count == 3)
    }

    // MARK: What each cell was showing

    @Test func theSelectedFileSurvivesARoundTrip() throws {
        let cell = group(["/a.ts", "/b.ts"], selected: "/a.ts", hostsTerminal: true)
        let decoded = try roundTrip(EditorGridState(.leaf(cell), activeGroupID: cell.id))

        let rebuilt = try #require(decoded.rebuilt(isOpen: allOpen))
        #expect(rebuilt.tree.groups[0].tabs.selectedPath == "/a.ts")
    }

    /// Looking at the shell with files open is a state of its own, and the
    /// one the terminal's cell is most often left in.
    @Test func aCellLeftOnTheTerminalComesBackOnTheTerminal() throws {
        let cell = group(["/a.ts"], hostsTerminal: true)
        let decoded = try roundTrip(EditorGridState(.leaf(cell), activeGroupID: cell.id))

        let rebuilt = try #require(decoded.rebuilt(isOpen: allOpen))
        #expect(rebuilt.tree.groups[0].tabs.showsTerminal)
    }

    /// The review is not a file. Its cell comes back on something that is
    /// still there rather than on a git scope that may not be.
    @Test func aCellLeftOnTheReviewComesBackOnAFile() throws {
        var tabs = EditorTabSet()
        tabs.open("/a.ts")
        tabs.openReview(.branch(root: "/repo"))
        let cell = EditorGroup(tabs: tabs, hostsTerminal: false)
        let terminal = group([], hostsTerminal: true)
        let tree = EditorGroupTree.split(.init(
            direction: .horizontal, first: .leaf(terminal), second: .leaf(cell)))

        let decoded = try roundTrip(EditorGridState(tree, activeGroupID: cell.id))
        let rebuilt = try #require(decoded.rebuilt(isOpen: allOpen))

        let restored = try #require(rebuilt.tree.groups.first { !$0.hostsTerminal })
        #expect(restored.tabs.selectedPath == "/a.ts")
        #expect(!restored.tabs.showsReview)
    }

    @Test func theCellInFocusSurvivesARoundTrip() throws {
        let first = group(["/a.ts"], hostsTerminal: true)
        let second = group(["/b.ts"])
        let tree = EditorGroupTree.split(.init(
            direction: .horizontal, first: .leaf(first), second: .leaf(second)))

        let decoded = try roundTrip(EditorGridState(tree, activeGroupID: second.id))
        let rebuilt = try #require(decoded.rebuilt(isOpen: allOpen))

        let active = try #require(rebuilt.tree.group(rebuilt.activeGroupID))
        #expect(active.tabs.tabs.map(\.path) == ["/b.ts"])
    }

    // MARK: Pins

    /// A pin is a property of the tab, and the bar's order is derived from
    /// it — so a restored bar has to read pinned run first.
    @Test func pinnedTabsComeBackPinnedAndAtTheHead() throws {
        let cell = group(
            ["/a.ts", "/b.ts", "/c.ts"], pinned: ["/c.ts"], selected: "/a.ts", hostsTerminal: true)
        let decoded = try roundTrip(EditorGridState(.leaf(cell), activeGroupID: cell.id))

        let rebuilt = try #require(decoded.rebuilt(isOpen: allOpen))
        let tabs = rebuilt.tree.groups[0].tabs
        #expect(tabs.tabs.map(\.path) == ["/c.ts", "/a.ts", "/b.ts"])
        #expect(tabs.pinnedCount == 1)
        #expect(tabs.selectedPath == "/a.ts")
    }

    @Test func unpinnedTabsKeepTheirOrder() throws {
        let cell = group(["/a.ts", "/b.ts", "/c.ts"], hostsTerminal: true)
        let decoded = try roundTrip(EditorGridState(.leaf(cell), activeGroupID: cell.id))

        let rebuilt = try #require(decoded.rebuilt(isOpen: allOpen))
        #expect(rebuilt.tree.groups[0].tabs.tabs.map(\.path) == ["/a.ts", "/b.ts", "/c.ts"])
        #expect(rebuilt.tree.groups[0].tabs.pinnedCount == 0)
    }

    // MARK: A file that is no longer there

    @Test func aMissingFileCostsItsOwnTabAndNothingElse() throws {
        let cell = group(["/a.ts", "/gone.ts", "/c.ts"], selected: "/c.ts", hostsTerminal: true)
        let decoded = try roundTrip(EditorGridState(.leaf(cell), activeGroupID: cell.id))

        let rebuilt = try #require(decoded.rebuilt(isOpen: { $0 != "/gone.ts" }))
        let tabs = rebuilt.tree.groups[0].tabs
        #expect(tabs.tabs.map(\.path) == ["/a.ts", "/c.ts"])
        #expect(tabs.selectedPath == "/c.ts")
    }

    /// The selection is the tab that went missing: the cell has to land on
    /// something rather than on a path with nothing behind it.
    @Test func aMissingSelectedFileLeavesTheCellOnSomethingElse() throws {
        let cell = group(["/a.ts", "/gone.ts"], selected: "/gone.ts", hostsTerminal: true)
        let decoded = try roundTrip(EditorGridState(.leaf(cell), activeGroupID: cell.id))

        let rebuilt = try #require(decoded.rebuilt(isOpen: { $0 != "/gone.ts" }))
        let tabs = rebuilt.tree.groups[0].tabs
        #expect(tabs.tabs.map(\.path) == ["/a.ts"])
        #expect(tabs.showsTerminal)
    }

    /// A cell whose every file is gone is the grid's vacant cell, and the
    /// grid's own answer to that is to give the space to the sibling.
    @Test func aCellThatLosesEveryFileCollapsesIntoItsSibling() throws {
        let kept = group(["/a.ts"], hostsTerminal: true)
        let lost = group(["/gone.ts", "/also-gone.ts"])
        let tree = EditorGroupTree.split(.init(
            direction: .horizontal, first: .leaf(kept), second: .leaf(lost)))

        let decoded = try roundTrip(EditorGridState(tree, activeGroupID: lost.id))
        let rebuilt = try #require(decoded.rebuilt(isOpen: { $0 == "/a.ts" }))

        #expect(rebuilt.tree.groups.count == 1)
        #expect(rebuilt.tree.groups[0].tabs.tabs.map(\.path) == ["/a.ts"])
    }

    /// Focus was in the cell that collapsed. It has to land somewhere that
    /// exists, or the grid draws from a cell it cannot find.
    @Test func focusFallsToASurvivingCell() throws {
        let kept = group(["/a.ts"], hostsTerminal: true)
        let lost = group(["/gone.ts"])
        let tree = EditorGroupTree.split(.init(
            direction: .horizontal, first: .leaf(kept), second: .leaf(lost)))

        let decoded = try roundTrip(EditorGridState(tree, activeGroupID: lost.id))
        let rebuilt = try #require(decoded.rebuilt(isOpen: { $0 == "/a.ts" }))

        #expect(rebuilt.tree.group(rebuilt.activeGroupID) != nil)
    }

    /// Every file is gone. There is nothing to put back, and the window is
    /// left in the shape it starts in rather than in a grid of empty cells.
    @Test func aGridWithNothingLeftRestoresNothing() throws {
        let cell = group(["/gone.ts"], hostsTerminal: true)
        let decoded = try roundTrip(EditorGridState(.leaf(cell), activeGroupID: cell.id))

        #expect(decoded.rebuilt(isOpen: { _ in false }) == nil)
    }

    // MARK: The terminal's cell

    /// Invariant 1 of the tree, over a file: with no host there is no way
    /// back to the shell.
    @Test func theTerminalHostSurvivesARoundTrip() throws {
        let first = group(["/a.ts"])
        let second = group(["/b.ts"], hostsTerminal: true)
        let tree = EditorGroupTree.split(.init(
            direction: .vertical, first: .leaf(first), second: .leaf(second)))

        let decoded = try roundTrip(EditorGridState(tree, activeGroupID: first.id))
        let rebuilt = try #require(decoded.rebuilt(isOpen: allOpen))

        let host = try #require(rebuilt.tree.terminalHost)
        #expect(rebuilt.tree.group(host)?.tabs.tabs.map(\.path) == ["/b.ts"])
    }

    /// A file that names no host — hand-edited, or written by another build.
    /// The grid must not come back without a terminal in it.
    @Test func aGridWithNoRecordedHostGetsOne() throws {
        let cell = group(["/a.ts"])
        var state = EditorGridState(.leaf(cell), activeGroupID: cell.id)
        state.root = .leaf(EditorGridState.Cell(
            files: [.init(path: "/a.ts", isPinned: false)],
            selectedFile: "/a.ts",
            hostsTerminal: false,
            isActive: true))

        let rebuilt = try #require(state.rebuilt(isOpen: allOpen))
        #expect(rebuilt.tree.terminalHost != nil)
    }

    /// The cell that hosts the terminal and holds nothing is not a file the
    /// reader had open, so it never stands in the way of the collapse.
    @Test func theTerminalCellSurvivesWithNoFilesInIt() throws {
        let terminal = group([], hostsTerminal: true)
        let files = group(["/a.ts"], selected: "/a.ts")
        let tree = EditorGroupTree.split(.init(
            direction: .horizontal, first: .leaf(terminal), second: .leaf(files)))

        let decoded = try roundTrip(EditorGridState(tree, activeGroupID: files.id))
        let rebuilt = try #require(decoded.rebuilt(isOpen: allOpen))

        #expect(rebuilt.tree.groups.count == 2)
        #expect(rebuilt.tree.terminalHost != nil)
    }

    // MARK: What is not worth saving

    /// The shape every window starts in. Recording it would put a block in
    /// the session file for every terminal that never opened a file.
    @Test func aGridWithNoFilesIsNotWorthSaving() {
        let bare = EditorGroupTree.leaf(EditorGroup(hostsTerminal: true))
        let state = EditorGridState(bare, activeGroupID: bare.groupIDs[0])

        #expect(state.paths.isEmpty)
        #expect(state.rebuilt(isOpen: allOpen) == nil)
    }
}
