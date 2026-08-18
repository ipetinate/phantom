@testable import Ghostty
import Testing

/// What each side of a diff asks git for.
///
/// Small, and worth pinning because one character decides whether the answer
/// is right: `base...HEAD` compares against the **merge base**, which is what a
/// pull request shows, while `base..HEAD` compares the two commits and reports
/// everything that landed on the base branch since the fork as though the
/// reader had written it. On a branch a week behind `main`, that is the
/// difference between reviewing your own work and reviewing everybody's.
struct GitDiffRangeTests {
    @Test func theWorkingTreeAsksForNoRangeAtAll() {
        #expect(GitDiffLoader.rangeArguments(for: .unstaged).isEmpty)
    }

    @Test func theIndexAsksForCached() {
        #expect(GitDiffLoader.rangeArguments(for: .staged) == ["--cached"])
    }

    /// The three dots, spelled out. A test that only checked the base name
    /// would pass with two of them.
    @Test func aBranchAsksAgainstTheMergeBase() {
        #expect(
            GitDiffLoader.rangeArguments(for: .branch(base: "origin/main"))
                == ["origin/main...HEAD"]
        )

        let range = GitDiffLoader.rangeArguments(for: .branch(base: "origin/main")).first ?? ""
        #expect(range.contains("..."), "two dots would compare the commits, not the fork point")
        #expect(!range.contains("...."))
    }

    /// A base is whatever git accepts as a revision — a tag, a sha, a remote
    /// branch — and none of it is escaped or rewritten on the way through.
    @Test func anyRevisionCanBeTheBase() {
        for base in ["main", "origin/HEAD", "v0.6.0", "1a2b3c4", "upstream/release-1.2"] {
            #expect(
                GitDiffLoader.rangeArguments(for: .branch(base: base)) == ["\(base)...HEAD"]
            )
        }
    }
}
