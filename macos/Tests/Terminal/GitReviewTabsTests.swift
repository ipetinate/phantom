import Foundation
@testable import Ghostty
import Testing

/// Reviews as tabs: what makes two of them different, where one opens, and
/// what the Git panel's commit list marks.
///
/// Written against `EditorCenter`'s gestures rather than against the tab set,
/// because the rules under test are about the *window*: a commit already open
/// in the other half of a split must not open again there, and the row the
/// commit list highlights follows whichever tab is in front.
///
/// Every case uses a root of its own. `GitReviewCenter` is a singleton and
/// these run in parallel, so two tests sharing a repository path would be two
/// tests sharing a review's identity.
@MainActor
struct GitReviewTabsTests {
    /// A real file, because `EditorCenter.open` loads one from disk.
    private func file(_ contents: String = "let a = 1") -> String {
        let path = NSTemporaryDirectory() + "phantom-review-\(UUID().uuidString).swift"
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func remove(_ paths: String...) {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
    }

    private func root() -> String { "/phantom-review-\(UUID().uuidString)" }

    private func commit(
        _ sha: String, in root: String, subject: String = "Fix the drag"
    ) -> GitReviewScope {
        .commit(root: root, sha: sha, subject: subject)
    }

    // MARK: What makes two review tabs different

    /// The identity rule, stated at the level it is written down: the
    /// repository and the work, and nothing about how either is drawn.
    @Test func aCommitIsTheSameReviewWhateverItsSubjectSays() {
        let root = root()

        #expect(
            commit("a1b2c3d4", in: root, subject: "Fix the drag").id
                == commit("a1b2c3d4", in: root, subject: "Fix the drag, again").id)
        #expect(commit("a1b2c3d4", in: root).id != commit("9f8e7d6c", in: root).id)
        #expect(GitReviewScope.branch(root: root).id != commit("a1b2c3d4", in: root).id)
    }

    /// The reason the subject is left out of the identity but kept on the
    /// tab: a reworded commit relabels the tab it already has.
    @Test func reopeningACommitRelabelsItsTabRatherThanAddingOne() {
        let center = EditorCenter()
        let root = root()

        center.openReview(commit("a1b2c3d4", in: root, subject: "Fix the drag"))
        center.openReview(commit("a1b2c3d4", in: root, subject: "Fix the drag properly"))

        #expect(center.openReviews.count == 1)
        #expect(center.review?.tabTitle == "a1b2c3d Fix the drag properly")
    }

    /// Clicking a commit that is already open lands on the tab it has. The
    /// commit list is a list of names, and clicking one twice is something
    /// people do without thinking.
    @Test func openingTheSameCommitTwiceKeepsOneTab() {
        let center = EditorCenter()
        let root = root()
        let path = file()
        defer { remove(path) }

        center.openReview(commit("a1b2c3d4", in: root))
        _ = center.open(URL(fileURLWithPath: path))
        #expect(center.review == nil, "opening a file takes the review off the front")

        center.openReview(commit("a1b2c3d4", in: root))

        #expect(center.openReviews.count == 1)
        #expect(center.review == commit("a1b2c3d4", in: root))
    }

    /// And two commits are two tabs, which is what a split can then compare.
    @Test func twoCommitsMakeTwoTabs() {
        let center = EditorCenter()
        let root = root()

        center.openReview(commit("a1b2c3d4", in: root))
        center.openReview(commit("9f8e7d6c", in: root))

        #expect(center.openReviews.count == 2)
        #expect(center.review == commit("9f8e7d6c", in: root))
        #expect(center.tabs.holdsReview(commit("a1b2c3d4", in: root).id))
    }

    /// The branch review and one of its commits are different tabs too — the
    /// commit is opened *from* the branch review, and it must not replace it.
    @Test func aCommitDoesNotReplaceTheBranchReview() {
        let center = EditorCenter()
        let root = root()

        center.showReview(.branch(root: root))
        center.openReview(commit("a1b2c3d4", in: root))

        #expect(center.openReviews.count == 2)
        #expect(center.review?.isCommit == true)
    }

    // MARK: Where a review opens

    /// A commit already open in the other half of a split is *there*, so
    /// clicking it moves the reader there rather than making a second copy of
    /// the same screen.
    @Test func openingACommitOpenElsewhereFocusesThatCell() {
        let center = EditorCenter()
        let root = root()
        let first = file()
        let second = file()
        defer { remove(first, second) }

        let host = center.activeGroupID
        _ = center.open(URL(fileURLWithPath: first))
        _ = center.open(URL(fileURLWithPath: second))
        center.drop(.file(second), on: host, zone: .trailing)
        let other = center.activeGroupID

        center.openReview(commit("a1b2c3d4", in: root))
        center.focus(host)
        center.openReview(commit("a1b2c3d4", in: root))

        #expect(center.activeGroupID == other)
        #expect(center.openReviews.count == 1)
        #expect(center.tabs(in: host).reviews.isEmpty)
    }

    /// Two commits, one per cell — the comparison this was asked for. Each
    /// cell answers for itself, which is what `EditorCenter.review` reads off
    /// the cell in focus rather than off the window.
    @Test func twoCellsCanShowTwoCommits() {
        let center = EditorCenter()
        let root = root()
        let first = file()
        let second = file()
        defer { remove(first, second) }

        let host = center.activeGroupID
        _ = center.open(URL(fileURLWithPath: first))
        _ = center.open(URL(fileURLWithPath: second))
        center.drop(.file(second), on: host, zone: .trailing)
        let other = center.activeGroupID

        center.openReview(commit("9f8e7d6c", in: root))
        center.focus(host)
        center.openReview(commit("a1b2c3d4", in: root))

        #expect(center.tabs(in: host).selectedReview == commit("a1b2c3d4", in: root))
        #expect(center.tabs(in: other).selectedReview == commit("9f8e7d6c", in: root))
    }

    // MARK: Closing

    /// Closing a review tab picks its neighbour to the left, the way closing
    /// a file tab does — so closing several in a row does not jump around the
    /// bar.
    @Test func closingAReviewPicksTheNeighbourToItsLeft() {
        let center = EditorCenter()
        let root = root()

        center.openReview(commit("a1b2c3d4", in: root))
        center.openReview(commit("9f8e7d6c", in: root))
        center.openReview(commit("11223344", in: root))
        center.selectReview(commit("9f8e7d6c", in: root).id)

        center.closeReview(commit("9f8e7d6c", in: root).id)

        #expect(center.openReviews.count == 2)
        #expect(center.review == commit("a1b2c3d4", in: root))
    }

    /// Closing the one in front is addressed by id, so it closes *that* tab
    /// and not whichever the focused cell happens to show.
    @Test func closingTheLastReviewFallsBackToTheFile() {
        let center = EditorCenter()
        let root = root()
        let path = file()
        defer { remove(path) }

        _ = center.open(URL(fileURLWithPath: path))
        center.openReview(commit("a1b2c3d4", in: root))

        center.closeReview()

        #expect(center.openReviews.isEmpty)
        #expect(center.tabs.selectedPath == path)
    }

    /// `showReview(nil)` is what the review screen's own close button calls,
    /// and it still means "take this down".
    @Test func showingNilClosesTheReviewInFront() {
        let center = EditorCenter()
        let root = root()

        center.openReview(commit("a1b2c3d4", in: root))
        center.showReview(nil)

        #expect(center.openReviews.isEmpty)
        #expect(center.review == nil)
    }

    // MARK: What the commit list highlights

    /// The highlight follows the tab in front, not the click. Two tabs open
    /// in one cell: the marked row changes when the reader switches tabs.
    @Test func theHighlightedRowFollowsTheFrontTab() {
        let center = EditorCenter()
        let root = root()
        let first = commit("a1b2c3d4", in: root)
        let second = commit("9f8e7d6c", in: root)

        center.openReview(first)
        center.openReview(second)

        #expect(GitReviewCenter.shared.isFront(second))
        #expect(!GitReviewCenter.shared.isFront(first))
        #expect(GitReviewCenter.shared.isOpen(first), "still open, just behind")

        center.selectReview(first.id)

        #expect(GitReviewCenter.shared.isFront(first))
        #expect(!GitReviewCenter.shared.isFront(second))
    }

    /// And across cells, which is the case a list holding its own `@State`
    /// gets wrong: moving focus to the other half of a split changes which
    /// commit is being looked at without any row being clicked.
    @Test func theHighlightFollowsFocusBetweenCells() {
        let center = EditorCenter()
        let root = root()
        let first = commit("a1b2c3d4", in: root)
        let second = commit("9f8e7d6c", in: root)
        let fileA = file()
        let fileB = file()
        defer { remove(fileA, fileB) }

        let host = center.activeGroupID
        _ = center.open(URL(fileURLWithPath: fileA))
        _ = center.open(URL(fileURLWithPath: fileB))
        center.drop(.file(fileB), on: host, zone: .trailing)
        let other = center.activeGroupID

        center.openReview(second)
        center.focus(host)
        center.openReview(first)

        #expect(GitReviewCenter.shared.isFront(first))
        #expect(!GitReviewCenter.shared.isFront(second))

        center.focus(other)

        #expect(GitReviewCenter.shared.isFront(second))
        #expect(!GitReviewCenter.shared.isFront(first))
        #expect(GitReviewCenter.shared.isOpen(first))
    }

    /// A commit nobody opened is neither, and a closed one stops being both —
    /// otherwise the list would keep marking rows for tabs that are gone.
    @Test func aClosedReviewStopsBeingMarked() {
        let center = EditorCenter()
        let root = root()
        let scope = commit("a1b2c3d4", in: root)

        #expect(!GitReviewCenter.shared.isOpen(scope))

        center.openReview(scope)
        #expect(GitReviewCenter.shared.isOpen(scope))

        center.closeReview(scope.id)
        #expect(!GitReviewCenter.shared.isOpen(scope))
        #expect(!GitReviewCenter.shared.isFront(scope))
    }

    /// One window's reviews are not another's. Two windows report separately,
    /// so a second window opening nothing must not clear the first one's
    /// marks — the bug a single shared entry would have.
    @Test func anotherWindowDoesNotEraseTheMarks() {
        let center = EditorCenter()
        let other = EditorCenter()
        let root = root()
        let scope = commit("a1b2c3d4", in: root)

        center.openReview(scope)
        other.selectTerminal()

        #expect(GitReviewCenter.shared.isOpen(scope))
        #expect(GitReviewCenter.shared.isFront(scope))
    }
}
