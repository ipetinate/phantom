import Foundation
@testable import Ghostty
import Testing

/// Which pull requests come first in a group's list.
///
/// The interesting half is what counts as the reader's. Authorship alone was
/// the old answer, and it left a pull request somebody handed to them sitting
/// among thirty others.
struct PullRequestListSplitTests {
    private func pr(
        _ number: Int,
        author: String? = "someone",
        assignees: [String] = []
    ) -> GitStatusCenter.PullRequest {
        GitStatusCenter.PullRequest(
            number: number,
            title: "pull request \(number)",
            url: "https://github.com/acme/app/pull/\(number)",
            author: author,
            assignees: assignees)
    }

    // MARK: What counts as the reader's

    @Test func whatTheReaderOpenedIsTheirs() {
        let split = PullRequestListSplit.split([pr(1, author: "ada")], me: "ada")

        #expect(split.mine.map(\.number) == [1])
        #expect(split.others.isEmpty)
    }

    /// The half authorship misses. A pull request assigned to you is one you
    /// are expected to move.
    @Test func whatWasAssignedToTheReaderIsTheirs() {
        let split = PullRequestListSplit.split(
            [pr(1, author: "grace", assignees: ["ada"])], me: "ada")

        #expect(split.mine.map(\.number) == [1])
    }

    @Test func somebodyElsesPullRequestIsNotTheirs() {
        let split = PullRequestListSplit.split(
            [pr(1, author: "grace", assignees: ["alan"])], me: "ada")

        #expect(split.mine.isEmpty)
        #expect(split.others.map(\.number) == [1])
    }

    /// GitHub logins are case-insensitive, and `gh` prints the canonical
    /// spelling in one place and whatever was typed in another.
    @Test func caseDoesNotDecideWhoseItIs() {
        let split = PullRequestListSplit.split(
            [pr(1, author: "Ada"), pr(2, author: "grace", assignees: ["ADA"])], me: "ada")

        #expect(split.mine.map(\.number) == [1, 2])
    }

    // MARK: Order and honesty

    /// `gh` answers newest first, and that order is the only thing this does
    /// not decide.
    @Test func theOrderInsideEachGroupIsUntouched() {
        let split = PullRequestListSplit.split(
            [
                pr(9, author: "ada"),
                pr(8, author: "grace"),
                pr(7, author: "ada"),
                pr(6, author: "alan"),
            ],
            me: "ada")

        #expect(split.mine.map(\.number) == [9, 7])
        #expect(split.others.map(\.number) == [8, 6])
    }

    /// Until `gh` has said who is signed in, nothing is claimed for anybody.
    /// A list that guessed would put a stranger's work under "Yours".
    @Test func nothingIsClaimedBeforeTheLoginIsKnown() {
        let prs = [pr(1, author: "ada"), pr(2, author: "grace")]

        #expect(PullRequestListSplit.split(prs, me: nil).mine.isEmpty)
        #expect(PullRequestListSplit.split(prs, me: nil).others.count == 2)
        #expect(PullRequestListSplit.split(prs, me: "").mine.isEmpty)
    }

    /// A fork whose author `gh` cannot resolve. It belongs to the list, in
    /// the group that claims nothing about it.
    @Test func aPullRequestWithNoAuthorStillAppears() {
        let split = PullRequestListSplit.split([pr(1, author: nil)], me: "ada")

        #expect(split.others.map(\.number) == [1])
    }

    // MARK: The avatar's login

    /// Checked before the string reaches a URL. `gh` answers `app/dependabot`
    /// for some bots, and a login carrying a slash would build a request for
    /// a path this code never meant to fetch.
    @Test func onlyALoginShapedStringIsTurnedIntoAnAvatarURL() {
        #expect(GitHubAvatarStore.isPlausible("ada"))
        #expect(GitHubAvatarStore.isPlausible("ada-lovelace"))
        #expect(GitHubAvatarStore.isPlausible("dependabot"))

        #expect(!GitHubAvatarStore.isPlausible("app/dependabot"))
        #expect(!GitHubAvatarStore.isPlausible(""))
        #expect(!GitHubAvatarStore.isPlausible("../../etc/passwd"))
        #expect(!GitHubAvatarStore.isPlausible("ada lovelace"))
        #expect(!GitHubAvatarStore.isPlausible(String(repeating: "a", count: 40)))
    }
}
