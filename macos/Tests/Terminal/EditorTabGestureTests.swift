import CoreGraphics
import Foundation
import Testing

@testable import Ghostty

/// The decision a drag on a tab makes: reorder along the strip, detach into
/// the split drag, or stay a click.
///
/// Pinned here rather than exercised through the bar, because the whole point
/// of `EditorTabGesture` is that it needs no window. The bug it fixes is a
/// gesture that read the pointer wrong, and a test that had to build a view
/// before it could ask about the pointer would be testing the view.
///
/// Every `update` is assigned before it is asserted on, deliberately: it is a
/// mutating call on a value, and one made inside `#expect` is a call the macro
/// has to reach into an expression it has already captured.
struct EditorTabGestureTests {
    /// A tab wide enough that half of it clears `minimumStep`, so the numbers
    /// below are the ones the arithmetic actually uses.
    private static let tabWidth: CGFloat = 120

    private func fresh() -> EditorTabGesture {
        EditorTabGesture(tabWidth: Self.tabWidth)
    }

    private func sideways(_ width: CGFloat) -> CGSize {
        CGSize(width: width, height: 0)
    }

    // MARK: The threshold

    /// The report this whole gesture exists for: a click that moved a point on
    /// the way down opened the drop panel over the pane.
    @Test func aMovementUnderTheThresholdIsStillAClick() {
        var gesture = fresh()

        let step = gesture.update(CGSize(width: 3, height: 2))

        #expect(step == .idle)
        #expect(gesture.axis == nil)
    }

    /// The threshold is one distance, not a distance per axis: a movement
    /// small on both is still small once they are put together.
    @Test func theThresholdIsMeasuredDiagonally() {
        var gesture = fresh()

        /// Four and four is under five on either axis alone, over it together.
        let step = gesture.update(CGSize(width: 4, height: 4))

        #expect(step == .idle)
        #expect(gesture.axis == .along)
    }

    /// A press that wandered and came back is still a click.
    ///
    /// The travel is measured from the button rather than from the previous
    /// event, so four points out and four points back is four points — never
    /// the five that would name an axis.
    @Test func aPressThatWandersAndReturnsIsStillAClick() {
        var gesture = fresh()

        let out = gesture.update(sideways(4))
        #expect(out == .idle)

        let back = gesture.update(sideways(0))
        #expect(back == .idle)
        #expect(gesture.axis == nil)
    }

    /// Naming an axis is not yet a move.
    ///
    /// `EditorTabDragSource` withholds the click only on a tab that actually
    /// moved, so a press that cleared the threshold and went no further still
    /// selects the tab it was on.
    @Test func namingAnAxisIsNotYetAMove() {
        var gesture = fresh()

        let named = gesture.update(sideways(10))
        #expect(named == .idle)
        #expect(gesture.axis == .along)

        let further = gesture.update(sideways(12))
        #expect(further == .idle)
    }

    // MARK: Along the strip

    /// Sideways reorders, and never begins the session that splits the pane.
    @Test func aSidewaysMovementReordersAndNeverDetaches() {
        var gesture = fresh()

        /// Past the threshold, not yet past half a tab.
        let armed = gesture.update(CGSize(width: 8, height: 1))
        #expect(armed == .idle)
        #expect(gesture.axis == .along)

        let moved = gesture.update(CGSize(width: 60, height: 1))
        #expect(moved == .reorder(1))
        gesture.moved(1)

        /// Far enough down to detach, if the axis were still open to it.
        let pulled = gesture.update(CGSize(width: 60, height: 300))
        #expect(pulled == .idle)
        #expect(gesture.axis == .along)
    }

    /// The swap lands at half a tab's width, and every further half tab is one
    /// more place.
    @Test func eachHalfTabIsOnePlace() {
        var gesture = fresh()

        let first = gesture.update(sideways(60))
        #expect(first == .reorder(1))
        gesture.moved(1)

        let second = gesture.update(sideways(180))
        #expect(second == .reorder(1))
        gesture.moved(1)

        let third = gesture.update(sideways(190))
        #expect(third == .idle)
    }

    /// Dragging back to where the gesture began puts the tab back, which is
    /// what makes a reorder the cheap half of this gesture.
    @Test func draggingBackUndoesTheMove() {
        var gesture = fresh()

        let out = gesture.update(sideways(130))
        #expect(out == .reorder(1))
        gesture.moved(1)

        let back = gesture.update(sideways(0))
        #expect(back == .reorder(-1))
    }

    // MARK: Out of the strip

    /// The split drag begins only once the tab has left its row.
    @Test func pullingTheTabOutOfTheRowDetaches() {
        var gesture = fresh()

        /// Past the threshold, still inside the row.
        let armed = gesture.update(CGSize(width: 1, height: 8))
        #expect(armed == .idle)
        #expect(gesture.axis == .out)

        let detached = gesture.update(CGSize(width: 1, height: 20))
        #expect(detached == .detach)
    }

    /// Up and down are the same gesture.
    @Test func pullingUpDetachesTheSameWay() {
        var gesture = fresh()

        let step = gesture.update(CGSize(width: 1, height: -20))

        #expect(step == .detach)
    }

    /// One press begins one session. `mouseDragged` keeps arriving while a
    /// session is in flight, and a second `beginDraggingSession` is a second
    /// tab in the air.
    @Test func theSessionIsBegunOnce() {
        var gesture = fresh()

        let first = gesture.update(CGSize(width: 0, height: 20))
        #expect(first == .detach)

        let second = gesture.update(CGSize(width: 0, height: 40))
        #expect(second == .idle)
    }

    // MARK: The axis is decided once

    /// A hand that curves must not make the tab flip between reordering and
    /// detaching on its way to one place.
    @Test func anAxisChosenSidewaysSurvivesAPullDownwards() {
        var gesture = fresh()

        let armed = gesture.update(sideways(8))
        #expect(armed == .idle)
        #expect(gesture.axis == .along)

        let pulled = gesture.update(CGSize(width: 8, height: 200))
        #expect(pulled == .idle)
        #expect(gesture.axis == .along)
    }

    /// And the other way about: a tab already on its way out of the row does
    /// not start reordering because the hand drifted sideways.
    @Test func anAxisChosenOutwardsSurvivesAMoveSideways() {
        var gesture = fresh()

        let armed = gesture.update(CGSize(width: 0, height: 8))
        #expect(armed == .idle)
        #expect(gesture.axis == .out)

        let drifted = gesture.update(CGSize(width: 400, height: 8))
        #expect(drifted == .idle)
        #expect(gesture.axis == .out)
    }

    // MARK: The order that comes out

    @Test func draggingRightPutsTheTabAfterItsNeighbour() {
        var tabs = EditorTabSet()
        ["/a.ts", "/b.ts", "/c.ts"].forEach { tabs.open($0) }
        var gesture = fresh()

        drag(&gesture, &tabs, "/a.ts", by: 130)

        #expect(tabs.tabs.map(\.path) == ["/b.ts", "/a.ts", "/c.ts"])
    }

    @Test func draggingLeftPutsTheTabBeforeItsNeighbour() {
        var tabs = EditorTabSet()
        ["/a.ts", "/b.ts", "/c.ts"].forEach { tabs.open($0) }
        var gesture = fresh()

        drag(&gesture, &tabs, "/c.ts", by: -130)

        #expect(tabs.tabs.map(\.path) == ["/a.ts", "/c.ts", "/b.ts"])
    }

    /// A move the strip refuses must not leave the gesture counting it.
    ///
    /// The tab is already first, so dragging left does nothing. Dragging back
    /// to the origin then has to do nothing as well — counting the refused
    /// request would move a tab that had never moved.
    @Test func aRefusedMoveDoesNotDisplaceTheTabOnTheWayBack() {
        var tabs = EditorTabSet()
        ["/a.ts", "/b.ts", "/c.ts"].forEach { tabs.open($0) }
        var gesture = fresh()

        drag(&gesture, &tabs, "/a.ts", by: -130)
        #expect(tabs.tabs.map(\.path) == ["/a.ts", "/b.ts", "/c.ts"])

        drag(&gesture, &tabs, "/a.ts", by: 0)
        #expect(tabs.tabs.map(\.path) == ["/a.ts", "/b.ts", "/c.ts"])
    }

    /// The strip holds pinned tabs in their own run, and a drag stays inside
    /// it — the same rule the menu's Move Left and Move Right follow.
    @Test func aDragDoesNotCarryATabOutOfItsRun() {
        var tabs = EditorTabSet()
        ["/a.ts", "/b.ts"].forEach { tabs.open($0) }
        tabs.setPinned(true, for: "/a.ts")
        var gesture = fresh()

        drag(&gesture, &tabs, "/b.ts", by: -130)

        #expect(tabs.tabs.map(\.path) == ["/a.ts", "/b.ts"])
    }

    /// One sideways movement, applied to a strip the way the bar applies it:
    /// ask, move what the strip allows, and report back what moved.
    private func drag(
        _ gesture: inout EditorTabGesture,
        _ tabs: inout EditorTabSet,
        _ path: String,
        by width: CGFloat
    ) {
        guard case .reorder(let places) = gesture.update(sideways(width)) else { return }
        gesture.moved(tabs.move(path, by: places) ? places : 0)
    }
}
