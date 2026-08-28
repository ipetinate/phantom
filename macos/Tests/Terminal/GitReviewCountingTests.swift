import Foundation
@testable import Ghostty
import Testing

/// Two counts the branch review reports, both of which were wrong in the same
/// way: they counted more than they were asked about, and the excess looked
/// plausible.
///
/// Reported from one screen. A pull request with four commits by one person
/// carried the byline "Bernardo Hazin (25), Isac Petinate (12), Jefferson
/// Daniel (8), Karina Crispim (7)", and a conflict check that git answers with
/// four files said eight. Neither number is one a reader can check without
/// running git themselves, which is exactly why they have to be right.
struct GitReviewCountingTests {
    // MARK: The conflict list

    /// `merge-tree --write-tree --name-only` writes the paths **before** the
    /// blank line and its commentary after it. The parser read the commentary,
    /// so every conflicted file arrived twice — once for `Auto-merging` and
    /// once for `CONFLICT`.
    @Test func onlyTheNamedPathsCount() {
        let output = """
            5c1debb68540788b15354f15a63c37a892e14300
            package.json
            pnpm-lock.yaml
            src/components/AddressDrawer.vue
            src/components/UnitDrawer.vue

            Auto-merging package.json
            CONFLICT (content): Merge conflict in package.json
            Auto-merging pnpm-lock.yaml
            CONFLICT (content): Merge conflict in pnpm-lock.yaml
            Auto-merging src/components/AddressDrawer.vue
            CONFLICT (content): Merge conflict in src/components/AddressDrawer.vue
            Auto-merging src/components/UnitDrawer.vue
            CONFLICT (content): Merge conflict in src/components/UnitDrawer.vue
            """

        let paths = GitReviewProbe.conflictedPaths(in: output)

        #expect(paths.count == 4)
        #expect(paths == [
            "package.json",
            "pnpm-lock.yaml",
            "src/components/AddressDrawer.vue",
            "src/components/UnitDrawer.vue",
        ])
    }

    /// `Auto-merging` says git merged that file **successfully**. Counting it
    /// as a conflict is not an off-by-one, it is the opposite claim.
    @Test func autoMergingIsNeverAConflict() {
        let output = """
            5c1debb68540788b15354f15a63c37a892e14300
            only-this-one.txt

            Auto-merging untouched-a.txt
            Auto-merging untouched-b.txt
            CONFLICT (content): Merge conflict in only-this-one.txt
            """

        #expect(GitReviewProbe.conflictedPaths(in: output) == ["only-this-one.txt"])
    }

    @Test func theTreeItWroteIsNotAPath() {
        let output = """
            5c1debb68540788b15354f15a63c37a892e14300
            a.txt

            CONFLICT (content): Merge conflict in a.txt
            """

        #expect(GitReviewProbe.conflictedPaths(in: output) == ["a.txt"])
    }

    /// A clean merge names nothing. `conflicts(branch:target:in:)` never gets
    /// here — it reads the exit status first — but a parser that invented a
    /// path from an empty answer would turn a clean branch into a warning.
    @Test func nothingNamedIsNothingConflicting() {
        #expect(GitReviewProbe.conflictedPaths(in: "").isEmpty)
        #expect(GitReviewProbe.conflictedPaths(
            in: "5c1debb68540788b15354f15a63c37a892e14300\n").isEmpty)
    }

    // MARK: The author tally

    /// The tally itself was never wrong — it was handed the wrong range. This
    /// pins what it does with what it is given, so the range fix has something
    /// underneath it.
    @Test func authorsAreCountedAndOrdered() {
        let authors = GitReviewProbe.tally(authorLines: """
            Isac Petinate
            Isac Petinate
            Bernardo Hazin
            Isac Petinate
            """)

        #expect(authors.count == 2)
        #expect(authors.first?.name == "Isac Petinate")
        #expect(authors.first?.commits == 3)
    }

    /// Ordered by name when the counts tie, so the header does not reshuffle
    /// itself between two refreshes.
    @Test func aTieIsBrokenByName() {
        let authors = GitReviewProbe.tally(authorLines: "Zoe\nAda\n")

        #expect(authors.map(\.name) == ["Ada", "Zoe"])
    }

    @Test func blankLinesAreNotAuthors() {
        let authors = GitReviewProbe.tally(authorLines: "\n\nIsac Petinate\n\n")

        #expect(authors.count == 1)
        #expect(authors.first?.commits == 1)
    }
}
