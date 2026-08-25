import AppKit
import Foundation
@testable import Ghostty
import Testing

/// The open-file bookkeeping behind the editor's tab bar.
struct EditorTabSetTests {
    @Test func openingAddsATabAndSelectsIt() {
        var tabs = EditorTabSet()
        tabs.open("/a/App.ts")

        #expect(tabs.tabs.count == 1)
        #expect(tabs.selection == .file("/a/App.ts"))
        #expect(tabs.selected?.name == "App.ts")
    }

    /// Clicking a name in the explorer is the whole interaction, and people
    /// click the same one twice without thinking — that has to select the
    /// tab, never make a second one.
    @Test func reopeningSelectsRatherThanDuplicating() {
        var tabs = EditorTabSet()
        tabs.open("/a/App.ts")
        tabs.open("/a/Other.ts")
        tabs.open("/a/App.ts")

        #expect(tabs.tabs.count == 2)
        #expect(tabs.selection == .file("/a/App.ts"))
    }

    /// Closing the tab you are looking at moves to its left neighbour,
    /// which is what keeps closing several in a row from jumping around.
    @Test func closingTheSelectedTabSelectsTheOneToItsLeft() {
        var tabs = EditorTabSet()
        ["/a.ts", "/b.ts", "/c.ts"].forEach { tabs.open($0) }
        tabs.select("/b.ts")
        tabs.close("/b.ts")

        #expect(tabs.selection == .file("/a.ts"))
    }

    /// Closing the first tab has no left neighbour, so it takes what is now
    /// first rather than deselecting.
    @Test func closingTheFirstTabSelectsTheNewFirst() {
        var tabs = EditorTabSet()
        ["/a.ts", "/b.ts"].forEach { tabs.open($0) }
        tabs.select("/a.ts")
        tabs.close("/a.ts")

        #expect(tabs.selection == .file("/b.ts"))
    }

    /// Closing one you weren't looking at must not move the selection.
    @Test func closingAnUnselectedTabLeavesTheSelectionAlone() {
        var tabs = EditorTabSet()
        ["/a.ts", "/b.ts", "/c.ts"].forEach { tabs.open($0) }
        tabs.select("/c.ts")
        tabs.close("/a.ts")

        #expect(tabs.selection == .file("/c.ts"))
    }

    /// The rule the whole feature rests on: with nothing open the editor
    /// gives the pane back to the terminal.
    @Test func closingTheLastTabEmptiesTheSet() {
        var tabs = EditorTabSet()
        tabs.open("/only.ts")
        tabs.close("/only.ts")

        #expect(tabs.isEmpty)
        #expect(tabs.selection == .terminal)
    }

    @Test func closingSomethingNotOpenChangesNothing() {
        var tabs = EditorTabSet()
        tabs.open("/a.ts")
        tabs.close("/never-opened.ts")

        #expect(tabs.tabs.count == 1)
        #expect(tabs.selection == .file("/a.ts"))
    }

    @Test func selectingSomethingNotOpenIsIgnored() {
        var tabs = EditorTabSet()
        tabs.open("/a.ts")
        tabs.select("/b.ts")

        #expect(tabs.selection == .file("/a.ts"))
    }

    // MARK: Dirty state

    @Test func dirtyIsTrackedPerTab() {
        var tabs = EditorTabSet()
        ["/a.ts", "/b.ts"].forEach { tabs.open($0) }
        tabs.setDirty(true, for: "/a.ts")

        #expect(tabs.hasUnsavedChanges)
        #expect(tabs.tabs.first { $0.id == "/a.ts" }?.isDirty == true)
        #expect(tabs.tabs.first { $0.id == "/b.ts" }?.isDirty == false)
    }

    @Test func closingADirtyTabClearsTheWarning() {
        var tabs = EditorTabSet()
        tabs.open("/a.ts")
        tabs.setDirty(true, for: "/a.ts")
        tabs.close("/a.ts")

        #expect(!tabs.hasUnsavedChanges)
    }

    // MARK: Names

    /// `index.ts` twice is the ordinary case in a real project, not an
    /// edge — without the directory the two tabs are indistinguishable.
    @Test func duplicateNamesAskForTheirDirectory() {
        var tabs = EditorTabSet()
        tabs.open("/one/index.ts")
        tabs.open("/two/index.ts")

        let first = tabs.tabs[0]
        #expect(tabs.needsDirectory(for: first))
        #expect(first.directory == "/one")
    }

    @Test func uniqueNamesDoNotShowTheirDirectory() {
        var tabs = EditorTabSet()
        tabs.open("/one/index.ts")
        tabs.open("/two/main.ts")

        #expect(!tabs.needsDirectory(for: tabs.tabs[0]))
    }

    /// Closing the twin means the survivor no longer needs qualifying.
    @Test func theDirectoryDisappearsWhenTheClashDoes() {
        var tabs = EditorTabSet()
        tabs.open("/one/index.ts")
        tabs.open("/two/index.ts")
        tabs.close("/two/index.ts")

        #expect(!tabs.needsDirectory(for: tabs.tabs[0]))
    }

    @Test func filesDeletedOutsideTheAppStopBeingTabs() {
        var tabs = EditorTabSet()
        ["/a.ts", "/b.ts"].forEach { tabs.open($0) }
        tabs.remove(missing: ["/a.ts"])

        #expect(tabs.tabs.map(\.id) == ["/b.ts"])
    }
}

/// The guard that decides whether a file is worth opening at all.
struct FileOpenGuardTests {
    @Test func ordinarySourceOpens() {
        let text = Data("const a = 1\n".utf8)
        #expect(FileOpenGuard.verdict(size: text.count, prefix: text) == .open)
    }

    /// A NUL byte is what every binary format puts near its start, and the
    /// case that motivated this: a `.class` sent to `vim` fills the screen
    /// with control codes.
    @Test func aNulByteMeansBinary() {
        var data = Data("\u{FEFF}CAFEBABE".utf8)
        data.append(0)
        #expect(FileOpenGuard.verdict(size: data.count, prefix: data) == .binary)
    }

    @Test func sizeIsCheckedBeforeContent() {
        let huge = FileOpenGuard.maxBytes + 1
        #expect(FileOpenGuard.verdict(size: huge, prefix: Data()) == .tooLarge(bytes: huge))
    }

    @Test func exactlyTheLimitStillOpens() {
        #expect(FileOpenGuard.verdict(size: FileOpenGuard.maxBytes, prefix: Data()) == .open)
    }

    @Test func anEmptyFileOpens() {
        #expect(FileOpenGuard.verdict(size: 0, prefix: Data()) == .open)
    }

    /// Every refusal has to say something a person can act on, since the
    /// caller turns it into an offer to open the file elsewhere.
    @Test func everyRefusalExplainsItself() {
        #expect(FileOpenGuard.Verdict.open.reason == nil)
        #expect(FileOpenGuard.Verdict.binary.reason?.isEmpty == false)
        #expect(FileOpenGuard.Verdict.tooLarge(bytes: 20_000_000).reason?.isEmpty == false)
    }

    @Test func aMissingFileIsRefusedRatherThanCrashing() {
        #expect(FileOpenGuard.verdict(for: URL(fileURLWithPath: "/nope/none.txt")) == .binary)
    }
}

/// Keyboard shortcuts, and the rule that keeps them from stealing the
/// terminal's.
@MainActor
struct EditorCommandsTests {
    @Test func saveAndCloseAreClaimedWhileEditing() {
        #expect(EditorCommands.command(
            for: "s", modifiers: [.command], editorFocused: true, hasOpenFiles: true
        ) == .save)
        #expect(EditorCommands.command(
            for: "w", modifiers: [.command], editorFocused: true, hasOpenFiles: true
        ) == .closeTab)
        #expect(EditorCommands.command(
            for: "s", modifiers: [.command, .shift], editorFocused: true, hasOpenFiles: true
        ) == .saveAll)
    }

    /// The one that matters most. ⌘W closes a terminal tab and ⌘F opens the
    /// terminal's search; with the editor unfocused both have to pass
    /// straight through, or the app people actually use stops working.
    @Test func nothingIsClaimedWhenTheEditorIsNotFocused() {
        for key in ["s", "w", "f"] {
            #expect(EditorCommands.command(
                for: key, modifiers: [.command], editorFocused: false, hasOpenFiles: true
            ) == nil, "⌘\(key) was taken from the terminal")
        }
    }

    /// And with no file open there is no editor to speak of, focused or not.
    @Test func nothingIsClaimedWithNoOpenFiles() {
        #expect(EditorCommands.command(
            for: "w", modifiers: [.command], editorFocused: true, hasOpenFiles: false
        ) == nil)
    }

    @Test func plainKeystrokesAreNeverCommands() {
        #expect(EditorCommands.command(
            for: "s", modifiers: [], editorFocused: true, hasOpenFiles: true
        ) == nil)
    }

    /// ⌘F is deliberately absent: `NSTextView`'s own find bar already
    /// handles it once the editor has focus, so intercepting it here would
    /// replace a working search with a worse one.
    @Test func findIsLeftToTheTextView() {
        #expect(EditorCommands.command(
            for: "f", modifiers: [.command], editorFocused: true, hasOpenFiles: true
        ) == nil)
    }
}

/// The terminal as the pane's first tab.
///
/// The rule this replaced — "the pane shows the editor whenever any file is
/// open" — made the ordinary thing impossible: glance at the terminal and
/// come back. There was no way to express "a file is open and I am looking
/// at the shell", because the state was a *count* and not a choice.
struct PaneSelectionTests {
    private func withFiles(_ paths: [String]) -> EditorTabSet {
        var tabs = EditorTabSet()
        paths.forEach { tabs.open($0) }
        return tabs
    }

    @Test func anEmptyPaneIsTheTerminal() {
        let tabs = EditorTabSet()
        #expect(tabs.showsTerminal)
        #expect(tabs.selectedPath == nil)
    }

    /// And with nothing to switch to, there is no bar — a control that does
    /// nothing, costing the terminal a row of its height to say so.
    @Test func theBarIsAbsentWithNoFileOpen() {
        #expect(!EditorTabSet().showsTabBar)
        #expect(withFiles(["/a.ts"]).showsTabBar)
    }

    @Test func openingAFileShowsIt() {
        let tabs = withFiles(["/a.ts"])
        #expect(!tabs.showsTerminal)
        #expect(tabs.selectedPath == "/a.ts")
    }

    /// The point of the whole change: the terminal is reachable *while* a
    /// file is open, and the file is still there when you come back.
    @Test func theTerminalIsReachableWithAFileOpen() {
        var tabs = withFiles(["/a.ts"])
        tabs.selectTerminal()

        #expect(tabs.showsTerminal)
        #expect(tabs.showsTabBar, "the bar has to stay, or there is no way back")
        #expect(tabs.tabs.count == 1, "switching away must not close anything")
    }

    @Test func togglingAlternatesWithTheFileYouWereOn() {
        var tabs = withFiles(["/a.ts", "/b.ts"])
        tabs.select("/a.ts")

        tabs.toggleTerminal(lastFile: "/a.ts")
        #expect(tabs.showsTerminal)

        tabs.toggleTerminal(lastFile: "/a.ts")
        #expect(tabs.selectedPath == "/a.ts", "not /b.ts — the one you left")
    }

    /// With no file there is nothing to alternate with, so it stays put
    /// rather than inventing a destination.
    @Test func togglingWithNoFileDoesNothing() {
        var tabs = EditorTabSet()
        tabs.toggleTerminal(lastFile: nil)
        #expect(tabs.showsTerminal)
    }

    /// A file closed while you were looking at the terminal must not drag
    /// the pane back to the editor.
    @Test func closingAnUnselectedFileLeavesTheTerminalShowing() {
        var tabs = withFiles(["/a.ts", "/b.ts"])
        tabs.selectTerminal()
        tabs.close("/b.ts")

        #expect(tabs.showsTerminal)
        #expect(tabs.tabs.count == 1)
    }

    @Test func closingTheLastFileReturnsToTheTerminal() {
        var tabs = withFiles(["/a.ts"])
        tabs.close("/a.ts")

        #expect(tabs.showsTerminal)
        #expect(!tabs.showsTabBar)
    }

    @Test func numbersAddressFilesOneBased() {
        var tabs = withFiles(["/a.ts", "/b.ts", "/c.ts"])
        tabs.selectTerminal()

        tabs.selectFile(at: 2)
        #expect(tabs.selectedPath == "/b.ts")

        tabs.selectFile(at: 9)
        #expect(tabs.selectedPath == "/b.ts", "a number with no tab is ignored")

        tabs.selectFile(at: 0)
        #expect(tabs.selectedPath == "/b.ts")
    }
}

/// Which keys the pane claims — and, more to the point, which it refuses.
struct PaneCommandTests {
    private func command(
        _ characters: String,
        _ modifiers: NSEvent.ModifierFlags,
        hasOpenFiles: Bool = true
    ) -> EditorCommands.PaneCommand? {
        EditorCommands.paneCommand(
            for: characters,
            modifiers: modifiers,
            hasOpenFiles: hasOpenFiles
        )
    }

    @Test func optionCommandBackslashToggles() {
        #expect(command("\\", [.command, .option]) == .toggleTerminal)
    }

    @Test func optionCommandNumbersAddressTabs() {
        #expect(command("1", [.command, .option]) == .selectFile(1))
        #expect(command("9", [.command, .option]) == .selectFile(9))
    }

    /// `⌘1`–`⌘9` are Ghostty's `goto_tab` for **window** tabs. Claiming them
    /// would break the terminal, which is the app — the mistake `⌘W` invited.
    @Test func plainCommandNumbersBelongToTheWindowTabs() {
        #expect(command("1", .command) == nil)
        #expect(command("2", .command) == nil)
    }

    /// `⌃⇥` is `next_tab`, and `⌃\` sends a control character to the shell.
    @Test func controlCombinationsAreLeftAlone() {
        #expect(command("\\", .control) == nil)
        #expect(command("\\", [.control, .command]) == nil)
        #expect(command("1", [.control, .command]) == nil)
    }

    /// An extra modifier means a different gesture, not this one.
    @Test func shiftMakesItSomethingElse() {
        #expect(command("\\", [.command, .option, .shift]) == nil)
    }

    /// With one surface there is nothing to switch to, so the key passes
    /// through to whoever else wants it.
    @Test func nothingIsClaimedWithNoFileOpen() {
        #expect(command("\\", [.command, .option], hasOpenFiles: false) == nil)
        #expect(command("1", [.command, .option], hasOpenFiles: false) == nil)
    }
}

/// Where a pinned tab sits, and what may and may not move it there.
///
/// The whole ordering rule lives in `EditorTabSet`, which is a value with no
/// window and no view in it, so these are the tests that hold the bar's order
/// honest: the terminal first, then the pinned run, then the rest.
struct EditorTabPinningTests {
    private func withFiles(_ paths: [String]) -> EditorTabSet {
        var tabs = EditorTabSet()
        paths.forEach { tabs.open($0) }
        return tabs
    }

    private func order(_ tabs: EditorTabSet) -> [String] { tabs.tabs.map(\.path) }

    @Test func pinningMovesTheTabToTheHeadOfTheBar() {
        var tabs = withFiles(["/a.ts", "/b.ts", "/c.ts"])
        tabs.setPinned(true, for: "/c.ts")

        #expect(order(tabs) == ["/c.ts", "/a.ts", "/b.ts"])
        #expect(tabs.pinnedCount == 1)
        #expect(tabs.tab(for: "/c.ts")?.isPinned == true)
    }

    /// The run grows in the order things were pinned, so a second pin lands
    /// behind the first rather than displacing it.
    @Test func pinnedTabsKeepTheOrderTheyWerePinnedIn() {
        var tabs = withFiles(["/a.ts", "/b.ts", "/c.ts"])
        tabs.setPinned(true, for: "/c.ts")
        tabs.setPinned(true, for: "/b.ts")

        #expect(order(tabs) == ["/c.ts", "/b.ts", "/a.ts"])
        #expect(tabs.pinnedCount == 2)
    }

    /// Opening a file must not disturb the tabs the reader chose to keep at
    /// hand, so a new tab lands behind the whole pinned run.
    @Test func openingAFileLandsBehindThePinnedRun() {
        var tabs = withFiles(["/a.ts", "/b.ts"])
        tabs.setPinned(true, for: "/b.ts")
        tabs.open("/c.ts")

        #expect(order(tabs) == ["/b.ts", "/a.ts", "/c.ts"])
        #expect(tabs.pinnedCount == 1)
    }

    /// Unpinning returns the tab to the unpinned run at the nearest slot,
    /// rather than throwing it to the far end of a bar the reader may have to
    /// scroll to find it in.
    @Test func unpinningReturnsTheTabToTheHeadOfTheUnpinnedRun() {
        var tabs = withFiles(["/a.ts", "/b.ts", "/c.ts"])
        tabs.setPinned(true, for: "/c.ts")
        tabs.setPinned(true, for: "/b.ts")
        tabs.setPinned(false, for: "/c.ts")

        #expect(order(tabs) == ["/b.ts", "/c.ts", "/a.ts"])
        #expect(tabs.pinnedCount == 1)
        #expect(tabs.tab(for: "/c.ts")?.isPinned == false)
    }

    @Test func everyPinnedTabComesBeforeEveryUnpinnedOne() {
        var tabs = withFiles(["/a.ts", "/b.ts", "/c.ts", "/d.ts"])
        tabs.setPinned(true, for: "/d.ts")
        tabs.setPinned(true, for: "/a.ts")
        tabs.setPinned(false, for: "/d.ts")
        tabs.open("/e.ts")

        let boundary = tabs.pinnedCount
        let head = tabs.tabs.prefix(boundary).allSatisfy(\.isPinned)
        let rest = tabs.tabs.dropFirst(boundary).allSatisfy { !$0.isPinned }
        #expect(head, "a tab before the boundary is not pinned")
        #expect(rest, "a tab after the boundary is pinned")
    }

    @Test func movingReordersWithinThePinnedRun() {
        var tabs = withFiles(["/a.ts", "/b.ts", "/c.ts"])
        tabs.setPinned(true, for: "/a.ts")
        tabs.setPinned(true, for: "/b.ts")

        let moved = tabs.move("/b.ts", by: -1)
        #expect(moved)
        #expect(order(tabs) == ["/b.ts", "/a.ts", "/c.ts"])
    }

    /// The boundary between the runs is not a place a move may cross: a tab
    /// carried over it would be pinned by its position and not by its own
    /// flag, which is the one way this array can come to disagree with itself.
    @Test func aMoveCannotCrossTheBoundaryBetweenTheRuns() {
        var tabs = withFiles(["/a.ts", "/b.ts", "/c.ts"])
        tabs.setPinned(true, for: "/a.ts")

        let outOfTheRun = tabs.move("/a.ts", by: 1)
        #expect(!outOfTheRun, "the last pinned tab has nowhere to go on the right")
        #expect(order(tabs) == ["/a.ts", "/b.ts", "/c.ts"])

        let intoTheRun = tabs.move("/b.ts", by: -1)
        #expect(!intoTheRun, "the first unpinned tab has nowhere to go on the left")
        #expect(order(tabs) == ["/a.ts", "/b.ts", "/c.ts"])
    }

    @Test func aMoveOffEitherEndOfTheBarIsRefused() {
        var tabs = withFiles(["/a.ts", "/b.ts"])

        let offTheLeft = tabs.move("/a.ts", by: -1)
        let offTheRight = tabs.move("/b.ts", by: 1)
        #expect(!offTheLeft)
        #expect(!offTheRight)
        #expect(order(tabs) == ["/a.ts", "/b.ts"])
    }

    @Test func aTabThatIsNotOpenCannotBePinnedOrMoved() {
        var tabs = withFiles(["/a.ts"])
        tabs.setPinned(true, for: "/nowhere.ts")

        let moved = tabs.move("/nowhere.ts", by: 1)
        #expect(!moved)
        #expect(order(tabs) == ["/a.ts"])
        #expect(tabs.pinnedCount == 0)
    }

    /// Pinning is about position, not about permanence — a pinned tab closes
    /// on the ordinary gesture, like any other.
    @Test func aPinnedTabClosesLikeAnyOther() {
        var tabs = withFiles(["/a.ts", "/b.ts"])
        tabs.setPinned(true, for: "/a.ts")
        tabs.close("/a.ts")

        #expect(order(tabs) == ["/b.ts"])
        #expect(tabs.selection == .file("/b.ts"))
    }

    /// A tab dragged into another cell arrives whole: the pin is the tab's,
    /// not the bar's, and so is the dirty dot.
    @Test func anAdoptedTabKeepsItsPinAndItsDot() {
        var source = withFiles(["/a.ts"])
        source.setPinned(true, for: "/a.ts")
        source.setDirty(true, for: "/a.ts")

        var destination = withFiles(["/x.ts", "/y.ts"])
        guard let travelling = source.tab(for: "/a.ts") else {
            Issue.record("the tab to move is missing")
            return
        }
        destination.adopt(travelling)

        #expect(order(destination) == ["/a.ts", "/x.ts", "/y.ts"])
        #expect(destination.tab(for: "/a.ts")?.isPinned == true)
        #expect(destination.tab(for: "/a.ts")?.isDirty == true)
        #expect(destination.selection == .file("/a.ts"))
    }

    /// An unpinned arrival lands at the end, behind the destination's own
    /// pinned run rather than in front of it.
    @Test func anAdoptedUnpinnedTabLandsBehindTheHostsPins() {
        var destination = withFiles(["/x.ts", "/y.ts"])
        destination.setPinned(true, for: "/y.ts")
        destination.adopt(EditorTab(path: "/a.ts"))

        #expect(order(destination) == ["/y.ts", "/x.ts", "/a.ts"])
    }

    /// Adopting a file the destination already has selects it instead of
    /// making a second tab — the same rule `open` follows, for the same
    /// reason: two live editors over one file would need a shared buffer.
    @Test func adoptingAFileTheCellAlreadyHasSelectsIt() {
        var destination = withFiles(["/x.ts", "/y.ts"])
        destination.adopt(EditorTab(path: "/x.ts", isPinned: true))

        #expect(order(destination) == ["/x.ts", "/y.ts"])
        #expect(destination.tab(for: "/x.ts")?.isPinned == false, "the resident tab is unchanged")
        #expect(destination.selection == .file("/x.ts"))
    }

    /// A rename keeps the tab where it is, pin and all.
    @Test func renamingKeepsThePin() {
        var tabs = withFiles(["/a.ts", "/b.ts"])
        tabs.setPinned(true, for: "/a.ts")
        tabs.repath(from: "/a.ts", to: "/renamed.ts")

        #expect(order(tabs) == ["/renamed.ts", "/b.ts"])
        #expect(tabs.tab(for: "/renamed.ts")?.isPinned == true)
    }

    /// Numbers address the tabs in the order they are drawn, so the first one
    /// is the leftmost tab in the bar — which, with a pin in it, is pinned.
    @Test func numbersFollowTheOrderTheBarDraws() {
        var tabs = withFiles(["/a.ts", "/b.ts", "/c.ts"])
        tabs.setPinned(true, for: "/c.ts")

        tabs.selectFile(at: 1)
        #expect(tabs.selectedPath == "/c.ts")
    }
}
