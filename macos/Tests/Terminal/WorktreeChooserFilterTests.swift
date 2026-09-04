import Foundation
@testable import Ghostty
import Testing

/// What a reader typing into the worktree chooser gets back.
///
/// The sectioned case is what earns the suite. A workspace draws one section
/// per repository, and the two ways a section can hold nothing — the query
/// rejected everything in it, or its list has not arrived — look identical
/// from the view and must not be treated alike.
struct WorktreeChooserFilterTests {
    private func worktree(_ path: String, branch: String? = nil) -> GitWorktree {
        GitWorktree(
            path: path,
            head: "9f0e1b7",
            branch: branch,
            isMain: false,
            isBare: false,
            isDetached: branch == nil,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil
        )
    }

    /// The chooser's own row label: the branch, or the folder for a detached
    /// checkout.
    private let name: (GitWorktree) -> String = { worktree in
        worktree.branch ?? (worktree.path as NSString).lastPathComponent
    }

    private func section(
        _ root: String,
        _ branches: [String],
        isListed: Bool = true
    ) -> WorktreeChooserSection {
        WorktreeChooserSection(
            root: root,
            worktrees: branches.map { worktree("/w/\($0)", branch: $0) },
            isListed: isListed)
    }

    private func branches(_ sections: [WorktreeChooserSection]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: sections.map { section in
            (section.root, section.worktrees.compactMap(\.branch))
        })
    }

    // MARK: One list

    @Test func anEmptyQueryKeepsEverythingInOrder() {
        let list = [
            worktree("/w/main", branch: "main"),
            worktree("/w/gamma", branch: "feat/gamma-310"),
            worktree("/w/spike"),
        ]
        #expect(WorktreeChooserFilter.matches(list, query: "", name: name) == list)
        #expect(WorktreeChooserFilter.matches(list, query: "   ", name: name) == list)
    }

    /// Delegated to `BranchFilter`, and this is the check that it stayed
    /// delegated: a substring anywhere in the name, case ignored.
    @Test func theMatchIsTheBranchPickersOwn() {
        let list = [
            worktree("/w/one", branch: "feat/GAMMA-310"),
            worktree("/w/two", branch: "fix/beta-4"),
        ]
        #expect(WorktreeChooserFilter.matches(list, query: "gamma-310", name: name)
            .compactMap(\.branch) == ["feat/GAMMA-310"])
    }

    /// A detached checkout has no branch, so its folder is the only name it
    /// has — and the only text the reader can see to type.
    @Test func aDetachedCheckoutMatchesOnItsFolder() {
        let list = [worktree("/w/spike-42")]
        #expect(WorktreeChooserFilter.matches(list, query: "spike", name: name).count == 1)
    }

    // MARK: Sections

    @Test func anEmptyQueryIsEverySectionUntouched() {
        let all = [
            section("/repos/alpha", ["main", "feat/a-1"]),
            section("/repos/beta", ["main"]),
        ]
        #expect(WorktreeChooserFilter.sections(all, query: "", name: name) == all)
    }

    @Test func theQueryAppliesInsideEverySection() {
        let all = [
            section("/repos/alpha", ["main", "feat/gamma-310"]),
            section("/repos/beta", ["main", "fix/gamma-477", "chore/ts"]),
        ]
        let shown = WorktreeChooserFilter.sections(all, query: "gamma", name: name)

        #expect(branches(shown) == [
            "/repos/alpha": ["feat/gamma-310"],
            "/repos/beta": ["fix/gamma-477"],
        ])
    }

    /// The reason the sectioned case exists at all: a heading over nothing is
    /// a row the reader has to read to learn it is empty.
    @Test func aSectionTheQueryEmptiesDisappears() {
        let all = [
            section("/repos/alpha", ["main", "feat/gamma-310"]),
            section("/repos/beta", ["main", "chore/ts"]),
        ]
        let shown = WorktreeChooserFilter.sections(all, query: "gamma", name: name)

        #expect(shown.map(\.root) == ["/repos/alpha"])
    }

    @Test func nothingMatchingAnywhereIsNoSections() {
        let all = [
            section("/repos/alpha", ["main"]),
            section("/repos/beta", ["main"]),
        ]
        #expect(WorktreeChooserFilter.sections(all, query: "release/2019", name: name).isEmpty)
    }

    /// The caller's order is `WorktreeScope`'s, and the popover draws its
    /// sections in it. Re-ranking by how well a section matched would move
    /// the repository the reader was aiming at.
    @Test func theSectionOrderSurvives() {
        let all = [
            section("/repos/zeta", ["feat/gamma-1"]),
            section("/repos/alpha", ["feat/gamma-2"]),
            section("/repos/beta", ["chore/ts"]),
        ]
        let shown = WorktreeChooserFilter.sections(all, query: "gamma", name: name)

        #expect(shown.map(\.root) == ["/repos/zeta", "/repos/alpha"])
    }

    /// Typing a repository is a way of asking for all of it, so the section
    /// comes back whole rather than narrowed to the branches that happen to
    /// share the repository's name.
    @Test func aRepositoryNameTakesItsWholeSection() {
        let all = [
            section("/repos/aurora", ["main", "chore/ts"]),
            section("/repos/beta", ["main"]),
        ]
        let shown = WorktreeChooserFilter.sections(all, query: "aurora", name: name)

        #expect(branches(shown) == ["/repos/aurora": ["main", "chore/ts"]])
    }

    /// Most of a workspace's sections have deliberately never been listed —
    /// see `WorktreeScope.polled` — so an unlisted section is not one the
    /// query rejected, and dropping it would make one letter look as though
    /// it had found nothing.
    @Test func aSectionWhoseListHasNotArrivedStays() {
        let all = [
            section("/repos/alpha", ["feat/gamma-310"]),
            section("/repos/beta", [], isListed: false),
            section("/repos/gone", [], isListed: true),
        ]
        let shown = WorktreeChooserFilter.sections(all, query: "gamma", name: name)

        #expect(shown.map(\.root) == ["/repos/alpha", "/repos/beta"])
    }
}
