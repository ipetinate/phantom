import Foundation
@testable import Ghostty
import Testing

/// Which group a tab belongs to, when a project group's root would also
/// claim it.
///
/// A project group claims by directory, which is what makes "open a
/// terminal in this project and it lands in the project's section" work.
/// The same rule, left unqualified, also reaches out and adopts terminals
/// that were deliberately created *outside* every group and merely happen
/// to be sitting in that directory — which reads as the sidebar moving
/// your terminal on its own. The assignment recorded at creation is what
/// separates the two, so these cover that it is honoured, including when
/// what was recorded is "no group at all".
@MainActor
struct SidebarGroupClaimTests {
    private func makeStore() -> SidebarGroupStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        return SidebarGroupStore(fileURL: url)
    }

    /// The claim itself still works: this is the behavior the explicit
    /// assignment has to override, so a test that it happens at all is what
    /// makes the next one meaningful.
    @Test func aProjectGroupClaimsAnUnassignedTabInItsRoot() {
        let store = makeStore()
        let group = store.createGroup(name: "Aurora", kind: .project(root: "/tmp/aurora"))

        let resolved = store.resolveGroup(surfaceId: UUID(), pwd: "/tmp/aurora/src")

        #expect(resolved?.id == group.id)
    }

    /// The regression: a terminal created outside every group stays outside,
    /// even when its directory sits inside a project group's root. Before
    /// the explicit "no group" assignment was recorded, nothing was written
    /// for the ungrouped case, so the claim above ran and the terminal
    /// jumped into the project's section on its own.
    @Test func anExplicitlyUngroupedTabIsNotClaimedByAProjectGroup() {
        let store = makeStore()
        _ = store.createGroup(name: "Aurora", kind: .project(root: "/tmp/aurora"))
        let surface = UUID()

        store.assign(surfaceId: surface, to: nil)

        #expect(store.resolveGroup(surfaceId: surface, pwd: "/tmp/aurora/src") == nil)
    }

    /// `cd`-ing into a project's root does not move a tab that was created
    /// outside it either — the assignment is what decides, not where the
    /// shell happens to be now.
    @Test func walkingIntoAProjectRootDoesNotAdoptAnUngroupedTab() {
        let store = makeStore()
        _ = store.createGroup(name: "Aurora", kind: .project(root: "/tmp/aurora"))
        let surface = UUID()
        store.assign(surfaceId: surface, to: nil)

        #expect(store.resolveGroup(surfaceId: surface, pwd: "/tmp/elsewhere") == nil)
        #expect(store.resolveGroup(surfaceId: surface, pwd: "/tmp/aurora") == nil)
    }

    /// An explicit assignment to a real group still wins, and keeps winning
    /// from a directory that belongs to a different project.
    @Test func anExplicitGroupAssignmentSurvivesADirectoryInAnotherProject() {
        let store = makeStore()
        let mine = store.createGroup(name: "Mine")
        _ = store.createGroup(name: "Aurora", kind: .project(root: "/tmp/aurora"))
        let surface = UUID()

        store.assign(surfaceId: surface, to: mine.id)

        #expect(store.resolveGroup(surfaceId: surface, pwd: "/tmp/aurora/src")?.id == mine.id)
    }

    /// A manual group has no root, so it never claims anyone by directory —
    /// membership there is only ever what was assigned.
    @Test func aManualGroupNeverClaimsByDirectory() {
        let store = makeStore()
        _ = store.createGroup(name: "Scratch")

        #expect(store.resolveGroup(surfaceId: UUID(), pwd: "/tmp/anything") == nil)
    }
}
