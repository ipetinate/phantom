import Foundation
@testable import Ghostty
import Testing

/// What survives a group deletion, for the two deletions the header offers.
///
/// The store is the half of this that can be wrong quietly. Deleting a group
/// and leaving its terminals loose in the list has to leave every one of them
/// exactly as it was — name, icon, color, position — because the terminals
/// are still on screen and the reader is still using them. Deleting a group
/// *with* its terminals has to leave nothing at all: an override keyed by a
/// surface that no longer exists is never read again and never pruned, since
/// `tabOverrides` has no age rule the way `assignments` does.
///
/// Both are written against a store on a throwaway file, so nothing here
/// touches the sidebar state of the machine running the tests.
@MainActor
struct SidebarGroupDeleteTests {
    private func makeStore() -> SidebarGroupStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        return SidebarGroupStore(fileURL: url)
    }

    /// Registers a tab into a group with a full set of per-tab state, which
    /// is what makes "leaves nothing behind" a measurable claim.
    private func addTab(
        _ store: SidebarGroupStore,
        to groupId: UUID?,
        name: String
    ) -> UUID {
        let surface = UUID()
        store.registerNewTab(surfaceId: surface, atStart: false)
        store.assign(surfaceId: surface, to: groupId)
        store.setTabOverride(surfaceId: surface, .init(name: name, icon: "hammer", color: .red))
        return surface
    }

    // MARK: - Deleting the group only

    /// The behavior that was there first and stays: the group goes, the
    /// terminals drop into the flat list, and everything the reader had set on
    /// them is still set.
    @Test func deletingOnlyTheGroupKeepsItsTabsAndTheirOverrides() {
        let store = makeStore()
        let group = store.createGroup(name: "Aurora")
        let first = addTab(store, to: group.id, name: "api")
        let second = addTab(store, to: group.id, name: "web")

        store.deleteGroup(group.id)

        #expect(store.groups.isEmpty)
        #expect(store.tabOverrides[first]?.name == "api")
        #expect(store.tabOverrides[second]?.name == "web")
        #expect(store.tabOrder == [first, second])
    }

    // MARK: - Deleting the group with its terminals

    @Test func deletingTheGroupWithItsTabsLeavesNothingForThem() {
        let store = makeStore()
        let group = store.createGroup(name: "Aurora")
        let first = addTab(store, to: group.id, name: "api")
        let second = addTab(store, to: group.id, name: "web")

        store.deleteGroup(group.id, closingTabs: [first, second])

        #expect(store.groups.isEmpty)
        #expect(store.assignments.isEmpty)
        #expect(store.tabOverrides.isEmpty)
        #expect(store.tabOrder.isEmpty)
    }

    /// A project group claims by directory, so a tab can be a member without
    /// ever having an assignment written for it. Naming the surfaces is what
    /// makes the cleanup reach those tabs — deriving membership from
    /// `assignments` would have missed exactly the tabs a project group is for.
    @Test func deletingAProjectGroupWithItsTabsClearsTabsItNeverAssigned() {
        let store = makeStore()
        let group = store.createGroup(name: "Aurora", kind: .project(root: "/tmp/aurora"))
        let claimed = UUID()
        store.registerNewTab(surfaceId: claimed, atStart: false)
        store.setTabOverride(surfaceId: claimed, .init(name: "claimed"))

        let resolved = store.resolveGroup(surfaceId: claimed, pwd: "/tmp/aurora/src")
        #expect(resolved?.id == group.id)

        store.deleteGroup(group.id, closingTabs: [claimed])

        #expect(store.tabOverrides[claimed] == nil)
        #expect(store.tabOrder.isEmpty)
    }

    /// The one case the sidebar cannot see: a member of the same group open in
    /// another window. It is not drawn under this header, so its terminal is
    /// not closed either — it only loses the group, and keeps the name and the
    /// position the reader gave it.
    @Test func aMemberNotNamedForClosingKeepsItsOverrideAndItsPlace() {
        let store = makeStore()
        let group = store.createGroup(name: "Aurora")
        let closing = addTab(store, to: group.id, name: "api")
        let elsewhere = addTab(store, to: group.id, name: "other window")

        store.deleteGroup(group.id, closingTabs: [closing])

        #expect(store.tabOverrides[closing] == nil)
        #expect(store.tabOverrides[elsewhere]?.name == "other window")
        #expect(store.tabOrder == [elsewhere])
        #expect(store.assignments[elsewhere] == nil)
    }

    /// The regression that costs the most and shows the least: a second group
    /// whose tabs share the one `tabOrder` list and the one override table.
    @Test func deletingAGroupWithItsTabsDoesNotTouchAnotherGroup() {
        let store = makeStore()
        let doomed = store.createGroup(name: "Aurora")
        let kept = store.createGroup(name: "Phantom")
        let doomedTab = addTab(store, to: doomed.id, name: "api")
        let keptFirst = addTab(store, to: kept.id, name: "core")
        let keptSecond = addTab(store, to: kept.id, name: "docs")

        store.deleteGroup(doomed.id, closingTabs: [doomedTab])

        #expect(store.groups.map(\.id) == [kept.id])
        #expect(store.assignments[keptFirst]?.groupId == kept.id)
        #expect(store.assignments[keptSecond]?.groupId == kept.id)
        #expect(store.tabOverrides[keptFirst]?.name == "core")
        #expect(store.tabOverrides[keptSecond]?.name == "docs")
        #expect(store.tabOrder == [keptFirst, keptSecond])
    }

    /// An ungrouped terminal is in the same two tables as everyone else, and
    /// nothing about deleting a group is allowed to reach it.
    @Test func deletingAGroupWithItsTabsDoesNotTouchAnUngroupedTab() {
        let store = makeStore()
        let group = store.createGroup(name: "Aurora")
        let member = addTab(store, to: group.id, name: "api")
        let loose = addTab(store, to: nil, name: "scratch")

        store.deleteGroup(group.id, closingTabs: [member])

        #expect(store.tabOverrides[loose]?.name == "scratch")
        #expect(store.tabOrder == [loose])
        #expect(store.assignments[loose] != nil)
        #expect(store.assignments[loose]?.groupId == nil)
    }

    /// Closing one member out of a longer list must leave the survivors in the
    /// order they were in, not rebuild it.
    @Test func theRemainingOrderKeepsItsSequence() {
        let store = makeStore()
        let group = store.createGroup(name: "Aurora")
        let first = addTab(store, to: nil, name: "one")
        let member = addTab(store, to: group.id, name: "api")
        let third = addTab(store, to: nil, name: "three")

        store.deleteGroup(group.id, closingTabs: [member])

        #expect(store.tabOrder == [first, third])
    }

    /// Nothing is named for closing: the call has to behave like the plain
    /// delete rather than like a no-op or a sweep.
    @Test func closingNoTabsIsTheSameAsDeletingTheGroupAlone() {
        let store = makeStore()
        let group = store.createGroup(name: "Aurora")
        let member = addTab(store, to: group.id, name: "api")

        store.deleteGroup(group.id, closingTabs: [])

        #expect(store.groups.isEmpty)
        #expect(store.assignments[member] == nil)
        #expect(store.tabOverrides[member]?.name == "api")
        #expect(store.tabOrder == [member])
    }
}
