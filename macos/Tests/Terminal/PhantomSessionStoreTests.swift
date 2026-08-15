import AppKit
import Foundation
@testable import Ghostty
import Testing

/// The decisions `PhantomSessionStore` makes about a saved session, none of
/// which had a test until every one of them had been wrong at least once.
///
/// Nothing here decodes a real `TerminalRestorableState`, and nothing here may
/// start to. Its surface tree is `SplitTree<Ghostty.SurfaceView>`, and
/// `SurfaceView.init(from:)` builds a live libghostty surface, spawns a login
/// shell and fires an agent resume — inside the test host, which *is*
/// Phantom.app. The store's decisions are reached through `PhantomSessionState`
/// and raw `Data` for exactly that reason.
struct PhantomSessionStoreTests {

    // MARK: Which Windows Count

    /// The bug this exists for: a window in the Dock reports `isVisible ==
    /// false`, so recording only visible windows dropped a minimized window
    /// and every tab in it from the saved session, and asking the same
    /// question the other way round claimed nothing was open — which restored
    /// the whole session on top of the windows still sitting in the Dock, two
    /// tabs to an agent conversation.
    @Test func aMinimizedWindowIsStillPartOfTheSession() {
        #expect(PhantomSessionStore.isPartOfSession(
            isVisible: false, isMiniaturized: true, isInTabGroup: false))
    }

    @Test func anOnScreenWindowIsPartOfTheSession() {
        #expect(PhantomSessionStore.isPartOfSession(
            isVisible: true, isMiniaturized: false, isInTabGroup: false))
    }

    /// The protection that has to survive every fix above: a closed window is
    /// neither visible nor minimized, AppKit leaves it in `NSApp.windows` long
    /// after its close, **and its `tabGroup` is nil** — measured, and the
    /// property that lets group membership be trusted at all. Counting closed
    /// windows is what made "is anything open" answer yes forever.
    @Test func aClosedWindowIsNotPartOfTheSession() {
        #expect(!PhantomSessionStore.isPartOfSession(
            isVisible: false, isMiniaturized: false, isInTabGroup: false))
    }

    /// The third wrong predicate, and the one that did the most damage: a
    /// background tab does not reliably report `isVisible`. Two tabs of the
    /// same group were measured disagreeing — one `true`, its neighbour
    /// `false` — so no reading of that flag includes them all.
    ///
    /// What it cost: restoring schedules a save, the save saw one window of
    /// four, and `session.json` was rewritten with the selected tab alone.
    /// Every restore threw the rest of the session away, and the next reopen
    /// brought back a single terminal.
    @Test func aBackgroundTabIsPartOfTheSessionEvenWhenItReportsInvisible() {
        #expect(PhantomSessionStore.isPartOfSession(
            isVisible: false, isMiniaturized: false, isInTabGroup: true))
    }

    /// The other half of the same group, which does report visible. Both must
    /// count, which is the whole point of not deciding this on `isVisible`.
    @Test func aVisibleTabIsPartOfTheSession() {
        #expect(PhantomSessionStore.isPartOfSession(
            isVisible: true, isMiniaturized: false, isInTabGroup: true))
    }

    /// Minimizing one tab minimizes the group, so every window in it reports
    /// miniaturized *and* keeps its group. Belt and braces, and it must not
    /// take a special case to stay true.
    @Test func aMinimizedTabGroupIsEntirelyPartOfTheSession() {
        #expect(PhantomSessionStore.isPartOfSession(
            isVisible: false, isMiniaturized: true, isInTabGroup: true))
    }

    // MARK: Whether The Reader Can Reach Anything

    /// The fourth mistake, and the one that made the app look wedged: these
    /// are two questions, and one predicate cannot answer both.
    ///
    /// A window's tabs stay in `NSApp.windows` after it closes, and their
    /// group membership outlives the close for long enough to matter. Asking
    /// "can the reader reach a window" with the session predicate therefore
    /// answered yes with nothing on screen — so New Window and a Dock click
    /// restored nothing and opened nothing. The Dock menu listed every
    /// terminal while clicking the icon did nothing at all.
    @Test func aLingeringTabOfAClosedWindowIsNotReachable() {
        #expect(!PhantomSessionStore.isReachable(isVisible: false, isMiniaturized: false))

        /// The same window, asked the other question: it still belongs to the
        /// session, which is why the two must not share a predicate.
        #expect(PhantomSessionStore.isPartOfSession(
            isVisible: false, isMiniaturized: false, isInTabGroup: true))
    }

    @Test func anOnScreenWindowIsReachable() {
        #expect(PhantomSessionStore.isReachable(isVisible: true, isMiniaturized: false))
    }

    /// A window in the Dock is reachable — the reader clicks it and it comes
    /// back. This is what stops New Window from restoring the session on top
    /// of windows that were only minimized.
    @Test func aMinimizedWindowIsReachable() {
        #expect(PhantomSessionStore.isReachable(isVisible: false, isMiniaturized: true))
    }

    @Test func aClosedWindowIsNotReachable() {
        #expect(!PhantomSessionStore.isReachable(isVisible: false, isMiniaturized: false))
    }

    // MARK: Deciding Whether To Write

    /// Closing the last window leaves the app running with nothing open, and
    /// writing that erased the session before anything could restore it.
    @Test func anEmptySaveNeverReplacesASession() {
        #expect(!PhantomSessionStore.shouldWrite(
            stateCount: 0,
            over: .readable(count: 3, isVersioned: true),
            mayShrink: true))
    }

    /// A file we cannot read is still a session — the reader may be one
    /// launch away from the build that reads it. Without this, a single
    /// decode failure compounded: the load returned nothing, so the guard
    /// never engaged, so the next save wrote `[]` over it.
    @Test func anEmptySaveNeverReplacesAnUnreadableSession() {
        #expect(!PhantomSessionStore.shouldWrite(
            stateCount: 0,
            over: .unreadable,
            mayShrink: true))
    }

    @Test func anEmptySaveIsFineWhenThereIsNothingToLose() {
        #expect(PhantomSessionStore.shouldWrite(
            stateCount: 0,
            over: .absent,
            mayShrink: true))
        #expect(PhantomSessionStore.shouldWrite(
            stateCount: 0,
            over: .readable(count: 0, isVersioned: true),
            mayShrink: true))
    }

    /// Deliberate, and the reason the empty guard is not a "never shrink"
    /// guard: closing one of three windows has to leave a session of two, or
    /// a session could only ever grow. This is the case the quitting rule
    /// below must not take away.
    @Test func aShorterSaveDoesReplaceALongerSession() {
        #expect(PhantomSessionStore.shouldWrite(
            stateCount: 1,
            over: .readable(count: 3, isVersioned: true),
            mayShrink: true))
    }

    // MARK: Deciding Whether To Write While Quitting

    /// The data loss this term exists for, measured: quitting through Review
    /// Windows with ten terminals open closes them one at a time, and the
    /// debounced save lands between the closes. Nine, eight, seven, six, five,
    /// four — the session file followed the teardown down, and the next launch
    /// restored what was left of it. The windows were not the reader giving
    /// terminals up, they were the quit taking them.
    @Test func aShorterSaveIsRefusedOnceTheAppIsQuitting() {
        #expect(!PhantomSessionStore.shouldWrite(
            stateCount: 9,
            over: .readable(count: 10, isVersioned: true),
            mayShrink: false))
    }

    /// Losing one terminal is the same bug as losing nine, and the guard is
    /// not a threshold.
    @Test func evenOneTerminalShortIsRefusedWhileQuitting() {
        #expect(!PhantomSessionStore.shouldWrite(
            stateCount: 2,
            over: .readable(count: 3, isVersioned: true),
            mayShrink: false))
    }

    /// Quitting is not a reason to stop writing. The window set is usually
    /// exactly what the session already holds, and that save carries
    /// everything about it that is not the count — which tab each window was
    /// showing, where it sat, what its title had been overridden to.
    @Test func aSaveOfTheSameLengthStillLandsWhileQuitting() {
        #expect(PhantomSessionStore.shouldWrite(
            stateCount: 3,
            over: .readable(count: 3, isVersioned: true),
            mayShrink: false))
    }

    /// A window opened after the last save is still the reader's, and quitting
    /// is not a reason to lose it either. Only shrinking is refused.
    @Test func aLongerSaveStillLandsWhileQuitting() {
        #expect(PhantomSessionStore.shouldWrite(
            stateCount: 4,
            over: .readable(count: 3, isVersioned: true),
            mayShrink: false))
    }

    /// The empty guard is the one that was already there, and quitting does
    /// not need it to be reached to hold: an empty save is short as well as
    /// empty, and refused for both reasons.
    @Test func anEmptySaveIsStillRefusedWhileQuitting() {
        #expect(!PhantomSessionStore.shouldWrite(
            stateCount: 0,
            over: .readable(count: 3, isVersioned: true),
            mayShrink: false))
    }

    /// Nothing to shrink from, so nothing to refuse. A first quit on a machine
    /// with no session file has to be able to write one.
    @Test func quittingStillWritesTheFirstSessionThereHasEverBeen() {
        #expect(PhantomSessionStore.shouldWrite(
            stateCount: 3,
            over: .absent,
            mayShrink: false))
    }

    /// An unreadable file has no count to be shorter than, so the shrink rule
    /// has nothing to say and the rule that was already here decides: real
    /// terminals replace a file we cannot make sense of, and an empty save
    /// leaves it alone.
    @Test func quittingLeavesAnUnreadableSessionToTheRuleThatAlreadyHadIt() {
        #expect(PhantomSessionStore.shouldWrite(
            stateCount: 3,
            over: .unreadable,
            mayShrink: false))
        #expect(!PhantomSessionStore.shouldWrite(
            stateCount: 0,
            over: .unreadable,
            mayShrink: false))
    }

    // MARK: Reading The File Without Building It

    /// The states in this file cannot be decoded — they have no surface tree
    /// — and counting them still has to work, because counting must not go
    /// anywhere near a decoder. A decode of the saved session builds every
    /// terminal it describes, and this count is taken on the launch path once
    /// per window macOS has in its own saved state.
    @Test func countsSavedTerminalsWithoutDecodingThem() {
        let json = """
        [{"focusedSurface":"a"},{"focusedSurface":"b"},{"focusedSurface":"c"}]
        """
        #expect(PhantomSessionStore.inspect(Data(json.utf8))
            == .readable(count: 3, isVersioned: false))
    }

    @Test func countsTheVersionedEnvelope() {
        let json = """
        {"version":1,"states":[{"focusedSurface":"a"},{"focusedSurface":"b"}]}
        """
        #expect(PhantomSessionStore.inspect(Data(json.utf8))
            == .readable(count: 2, isVersioned: true))
    }

    @Test func anEmptySessionIsReadableAndEmpty() {
        #expect(PhantomSessionStore.inspect(Data("[]".utf8))
            == .readable(count: 0, isVersioned: false))
    }

    /// A malformed file is recognized as such rather than read as an empty
    /// session, which is what keeps the next save from writing `[]` over it.
    @Test func aMalformedSessionFileIsLeftAlone() {
        let summary = PhantomSessionStore.inspect(Data("{not json".utf8))
        #expect(summary == .unreadable)
        #expect(!PhantomSessionStore.shouldWrite(
            stateCount: 0,
            over: summary,
            mayShrink: true))
    }

    @Test func anEmptyFileIsUnreadableRatherThanAnEmptySession() {
        #expect(PhantomSessionStore.inspect(Data()) == .unreadable)
    }

    /// The point of putting a version in the envelope: a session written by a
    /// newer Phantom is recognizable, so this build restores nothing from it
    /// and — with the guard above — does not overwrite it either.
    @Test func aSessionFromANewerBuildIsLeftAlone() {
        let json = """
        {"version":\(PhantomSessionStore.fileVersion + 1),"states":[{"focusedSurface":"a"}]}
        """
        let summary = PhantomSessionStore.inspect(Data(json.utf8))
        #expect(summary == .unreadable)
        #expect(!PhantomSessionStore.shouldWrite(
            stateCount: 0,
            over: summary,
            mayShrink: true))
    }

    @Test func anEnvelopeWithNoVersionIsUnreadable() {
        let json = """
        {"states":[{"focusedSurface":"a"}]}
        """
        #expect(PhantomSessionStore.inspect(Data(json.utf8)) == .unreadable)
    }

    // MARK: Tab Groups

    @Test func partitionsTabsFromStandaloneWindows() {
        let states = [
            FakeSessionState(id: 1, tabGroupID: 0, tabIndex: 0),
            FakeSessionState(id: 2),
            FakeSessionState(id: 3, tabGroupID: 1, tabIndex: 0),
            FakeSessionState(id: 4, tabGroupID: 0, tabIndex: 1),
            FakeSessionState(id: 5),
        ]

        let (groups, standalones) = PhantomSessionStore.partition(states)

        #expect(groups.count == 2)
        #expect(groups[0].map(\.id) == [1, 4])
        #expect(groups[1].map(\.id) == [3])
        #expect(standalones.map(\.id) == [2, 5])
    }

    @Test func aSessionOfOneWindowIsOneStandalone() {
        let (groups, standalones) = PhantomSessionStore.partition([FakeSessionState(id: 1)])
        #expect(groups.isEmpty)
        #expect(standalones.map(\.id) == [1])
    }

    /// The tab bar's order is the file's to keep, not the order the states
    /// happen to sit in.
    @Test func ordersTabsByTheirSavedPosition() {
        let group = [
            FakeSessionState(id: 1, tabGroupID: 0, tabIndex: 2),
            FakeSessionState(id: 2, tabGroupID: 0, tabIndex: 0),
            FakeSessionState(id: 3, tabGroupID: 0, tabIndex: 1),
        ]
        #expect(PhantomSessionStore.ordered(group).map(\.id) == [2, 3, 1])
    }

    /// A tab with no recorded position sorts last: it is the one we know
    /// nothing about, so it must not displace the ones we do.
    @Test func anUnpositionedTabSortsLast() {
        let group = [
            FakeSessionState(id: 1, tabGroupID: 0),
            FakeSessionState(id: 2, tabGroupID: 0, tabIndex: 0),
        ]
        #expect(PhantomSessionStore.ordered(group).map(\.id) == [2, 1])
    }

    // MARK: Which Tab Was Showing

    /// `tabIndex` is tab-bar order and says nothing about the selection, so a
    /// window of four tabs came back on the first one however far along the
    /// reader had been working.
    @Test func findsTheTabTheWindowWasShowing() {
        let ordered = [
            FakeSessionState(id: 1, tabGroupID: 0, tabIndex: 0, isSelectedTab: false),
            FakeSessionState(id: 2, tabGroupID: 0, tabIndex: 1, isSelectedTab: false),
            FakeSessionState(id: 3, tabGroupID: 0, tabIndex: 2, isSelectedTab: true),
        ]
        #expect(PhantomSessionStore.selectedIndex(in: ordered) == 2)
    }

    /// Sessions written before the selection was persisted record nothing,
    /// and the restore has to read that as "the first tab" rather than
    /// picking one.
    @Test func aSessionWithNoRecordedSelectionSelectsNothing() {
        let ordered = [
            FakeSessionState(id: 1, tabGroupID: 0, tabIndex: 0),
            FakeSessionState(id: 2, tabGroupID: 0, tabIndex: 1),
        ]
        #expect(PhantomSessionStore.selectedIndex(in: ordered) == nil)
    }

    // MARK: Frame And Fullscreen

    /// The regression test for a premise that was false for every window ever
    /// opened: `effectiveFullscreenMode` is `.native` from the moment a window
    /// loads, fullscreen or not, so a restore that trusted it put ordinary
    /// windows into fullscreen and threw away their frames as if those were
    /// fullscreen bounds.
    @Test func theFullscreenModeAloneDoesNotPutAWindowIntoFullscreen() {
        let ordinary = FakeSessionState(
            frame: CGRect(x: 10, y: 20, width: 951, height: 600),
            effectiveFullscreenMode: .native,
            isFullscreen: nil)

        #expect(PhantomSessionStore.restoredFullscreenMode(for: ordinary) == nil)
        #expect(PhantomSessionStore.restoredFrame(for: ordinary)
            == CGRect(x: 10, y: 20, width: 951, height: 600))
    }

    @Test func aWindowThatWasNotFullscreenGetsItsFrameBack() {
        let state = FakeSessionState(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            effectiveFullscreenMode: .native,
            isFullscreen: false)

        #expect(PhantomSessionStore.restoredFrame(for: state)
            == CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(PhantomSessionStore.restoredFullscreenMode(for: state) == nil)
    }

    /// A window that really was in fullscreen goes back into it, and its
    /// frame is refused: those are the fullscreen bounds, and applying them
    /// to a windowed window produces a giant, broken-looking thing.
    @Test func aFullscreenWindowGoesBackToFullscreenWithoutItsFrame() {
        let state = FakeSessionState(
            frame: CGRect(x: 0, y: 0, width: 3456, height: 2160),
            effectiveFullscreenMode: .native,
            isFullscreen: true)

        #expect(PhantomSessionStore.restoredFrame(for: state) == nil)
        #expect(PhantomSessionStore.restoredFullscreenMode(for: state) == .native)
    }

    @Test func aNonNativeFullscreenWindowComesBackInItsOwnMode() {
        let state = FakeSessionState(
            effectiveFullscreenMode: .nonNativePaddedNotch,
            isFullscreen: true)

        #expect(PhantomSessionStore.restoredFullscreenMode(for: state)
            == .nonNativePaddedNotch)
    }

    // MARK: Reading Sessions Written By Earlier Builds

    /// Two fields were added to the saved state — which tab was showing, and
    /// whether the window was fullscreen — and a session written before them
    /// has to keep decoding, or the reader opens the app to nothing.
    ///
    /// Decoded through `InternalState<MockView>`, never through
    /// `TerminalRestorableState`: same JSON, no live surfaces. See the note on
    /// this suite.
    @MainActor
    @Test func aSessionWrittenBeforeTheNewFieldsStillDecodes() throws {
        let json = """
        {
          "focusedSurface": "926F3F2A-824C-40C9-87CA-2CDCA4E11049",
          "surfaceTree": {
            "root": {"view": {"id": "926F3F2A-824C-40C9-87CA-2CDCA4E11049"}},
            "version": 1
          },
          "effectiveFullscreenMode": "native",
          "tabColor": null,
          "titleOverride": null,
          "frame": [[0, 0], [951, 600]],
          "tabGroupID": 0,
          "tabIndex": 1
        }
        """

        let state = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self,
            from: Data(json.utf8))

        #expect(state.tabGroupID == 0)
        #expect(state.tabIndex == 1)
        #expect(state.isSelectedTab == nil)
        #expect(state.isFullscreen == nil)
        #expect(state.frame == CGRect(x: 0, y: 0, width: 951, height: 600))
    }

    /// And the new fields round-trip, so what the save records is what the
    /// restore reads.
    @MainActor
    @Test func theNewFieldsRoundTrip() throws {
        let json = """
        {
          "focusedSurface": "AC5E829B-85FD-4C69-B196-2EE469C72A90",
          "surfaceTree": {
            "root": {"view": {"id": "AC5E829B-85FD-4C69-B196-2EE469C72A90"}},
            "version": 1
          },
          "effectiveFullscreenMode": "native",
          "tabColor": null,
          "titleOverride": null,
          "frame": null,
          "tabGroupID": 2,
          "tabIndex": 3,
          "isSelectedTab": true,
          "isFullscreen": true
        }
        """

        let decoded = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self,
            from: Data(json.utf8))
        #expect(decoded.isSelectedTab == true)
        #expect(decoded.isFullscreen == true)

        let reencoded = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self,
            from: reencoded)
        #expect(again.isSelectedTab == true)
        #expect(again.isFullscreen == true)
        #expect(again.tabIndex == 3)
    }
}

/// Everything the store reads from a saved state and nothing else — the point
/// of `PhantomSessionState` being a protocol.
private struct FakeSessionState: PhantomSessionState, Equatable {
    var id: Int = 0
    var tabGroupID: Int?
    var tabIndex: Int?
    var isSelectedTab: Bool?
    var frame: CGRect?
    var effectiveFullscreenMode: FullscreenMode?
    var isFullscreen: Bool?
}
