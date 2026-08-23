import Foundation
@testable import Ghostty
import Testing

/// Where a newly created tab lands in the sidebar's display order.
///
/// The rule these cover is the one behind "opening a file always opens a
/// terminal *beside* the current one": the panels list whatever the
/// selected terminal is looking at, so a terminal they spawn belongs next
/// to that terminal, not at the end of the list where it reads as
/// unrelated. `insert` is the seam — `SidebarView` renders `tabOrder`
/// directly, so getting the order right here is getting the UI right.
@MainActor
struct SidebarTabPlacementTests {
    private func makeStore() -> SidebarGroupStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        return SidebarGroupStore(fileURL: url)
    }

    @Test func newTabLandsDirectlyAfterItsAnchor() {
        let store = makeStore()
        let first = UUID(), second = UUID(), spawned = UUID()
        store.registerNewTab(surfaceId: first, atStart: false)
        store.registerNewTab(surfaceId: second, atStart: false)
        store.registerNewTab(surfaceId: spawned, atStart: false)

        store.insert(surfaceId: spawned, near: first, after: true, groupId: nil)

        let sorted = store.sorted([second, spawned, first], id: { $0 })
        #expect(sorted == [first, spawned, second])
    }

    /// A file opened from a terminal that sits inside a group produces a
    /// terminal in that same group — otherwise the new tab jumps out of
    /// the project it belongs to.
    @Test func newTabAdoptsTheAnchorsGroup() {
        let store = makeStore()
        let group = store.createGroup(name: "Project")
        let anchor = UUID(), spawned = UUID()
        store.registerNewTab(surfaceId: anchor, atStart: false)
        store.assign(surfaceId: anchor, to: group.id)
        store.registerNewTab(surfaceId: spawned, atStart: false)

        store.insert(surfaceId: spawned, near: anchor, after: true, groupId: group.id)

        #expect(store.resolveGroup(surfaceId: spawned, pwd: nil)?.id == group.id)
    }

    /// The ungrouped case has to stay ungrouped: `assign(to: nil)` records
    /// an explicit "no group", which is what keeps a later pwd-based
    /// project match from silently adopting the tab.
    @Test func anUngroupedAnchorKeepsTheNewTabUngrouped() {
        let store = makeStore()
        let anchor = UUID(), spawned = UUID()
        store.registerNewTab(surfaceId: anchor, atStart: false)
        store.registerNewTab(surfaceId: spawned, atStart: false)

        store.insert(surfaceId: spawned, near: anchor, after: true, groupId: nil)

        #expect(store.resolveGroup(surfaceId: spawned, pwd: nil) == nil)
    }

    /// The mechanism behind the fresh-install "new terminal lands
    /// second-to-last" bug, pinned so the cure stays understood: a tab that
    /// never entered `tabOrder` sorts after every ordered one, so it sits at
    /// the bottom and each newly registered tab lands in front of it. The
    /// cure is in `SidebarTabManager.refresh`, which registers every tab on
    /// first sight — the window's own first tab included — so this shape can
    /// only arise from a file that predates the order.
    @Test func aTabLeftOutOfTheOrderSinksBelowEveryRegisteredOne() {
        let store = makeStore()
        let unregistered = UUID(), second = UUID(), third = UUID()
        store.registerNewTab(surfaceId: second, atStart: false)
        store.registerNewTab(surfaceId: third, atStart: false)

        let sorted = store.sorted([unregistered, second, third], id: { $0 })
        #expect(sorted == [second, third, unregistered])
    }

    /// The healthy order after the cure: with every tab registered on first
    /// sight, a new tab registered at the end is the end of the list.
    @Test func registeringEveryTabOnSightKeepsNewTabsAtTheEnd() {
        let store = makeStore()
        let first = UUID(), second = UUID(), third = UUID()
        store.registerNewTab(surfaceId: first, atStart: false)
        store.registerNewTab(surfaceId: second, atStart: false)
        store.registerNewTab(surfaceId: third, atStart: false)

        let sorted = store.sorted([third, first, second], id: { $0 })
        #expect(sorted == [first, second, third])
    }

    /// Guards the self-insert case: a spawn whose anchor resolution went
    /// wrong must not corrupt the order by trying to place a tab next to
    /// itself.
    @Test func insertingATabNextToItselfIsANoOp() {
        let store = makeStore()
        let first = UUID(), second = UUID()
        store.registerNewTab(surfaceId: first, atStart: false)
        store.registerNewTab(surfaceId: second, atStart: false)

        store.insert(surfaceId: first, near: first, after: true, groupId: nil)

        #expect(store.sorted([second, first], id: { $0 }) == [first, second])
    }
}
