@testable import Ghostty
import Testing

/// What a reader typing into the branch picker gets back.
struct BranchFilterTests {
    private let branches = [
        "main",
        "feat/gamma-310",
        "feat/gamma-318-form",
        "fix/GAMMA-477",
        "origin/feat/gamma-310",
        "chore/enable-ts-strict",
    ]

    @Test func anEmptyQueryKeepsEverythingInOrder() {
        #expect(BranchFilter.matches(branches, query: "") == branches)
    }

    /// Whitespace alone is an empty query. A trailing space is what a reader
    /// leaves behind when they paste a branch name, and it must not empty the
    /// list — which is what an untrimmed substring match would do.
    @Test func whitespaceIsNotAQuery() {
        #expect(BranchFilter.matches(branches, query: "   ") == branches)
        #expect(BranchFilter.matches(branches, query: " main ") == ["main"])
    }

    /// The reason the match is a substring and not a prefix: the part of the
    /// name a reader remembers is the ticket, and it sits at the end.
    @Test func aQueryMatchesInsideTheName() {
        #expect(BranchFilter.matches(branches, query: "gamma-310")
            == ["feat/gamma-310", "origin/feat/gamma-310"])
    }

    @Test func caseDoesNotMatter() {
        #expect(BranchFilter.matches(branches, query: "gamma-477") == ["fix/GAMMA-477"])
        #expect(BranchFilter.matches(branches, query: "MAIN") == ["main"])
    }

    /// The caller's order survives the filter — the picker leans on it, since
    /// the lists it is given are sorted by commit date or by likelihood.
    @Test func theCallersOrderSurvives() {
        #expect(BranchFilter.matches(branches, query: "gamma")
            == ["feat/gamma-310", "feat/gamma-318-form", "fix/GAMMA-477",
                "origin/feat/gamma-310"])
    }

    @Test func nothingMatchingIsEmptyRatherThanEverything() {
        #expect(BranchFilter.matches(branches, query: "release/2019").isEmpty)
    }
}
