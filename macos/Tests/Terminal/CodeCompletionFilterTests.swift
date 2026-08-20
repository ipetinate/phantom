import Foundation
@testable import Ghostty
import Testing

/// The ordering of the list, which — because the list opens after one
/// character — is the whole of the experience.
///
/// **These assert orderings, never scores.** The numbers behind them will be
/// retuned; the orderings are the contract, and a test naming a score would
/// fail on an improvement rather than on a regression.
struct CodeCompletionFilterTests {
    private func item(
        _ label: String,
        kind: CodeCompletionItem.Kind = .variable,
        detail: String? = nil,
        filterText: String? = nil,
        sortText: String? = nil,
        isPreselected: Bool = false,
        source: CodeCompletionItem.Source = .server
    ) -> CodeCompletionItem {
        CodeCompletionItem(
            kind: kind,
            label: label,
            detail: detail,
            filterText: filterText,
            sortText: sortText,
            isPreselected: isPreselected,
            source: source
        )
    }

    private func labels(_ items: [CodeCompletionItem], _ query: String) -> [String] {
        CodeCompletionFilter.rank(items, query: query).map(\.label)
    }

    // MARK: - Matching

    @Test func aQueryThatIsNotASubsequenceIsRejected() {
        #expect(CodeCompletionFilter.match(query: "zq", candidate: "const") == nil)
        #expect(CodeCompletionFilter.match(query: "constant", candidate: "const") == nil)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(CodeCompletionFilter.match(query: "CON", candidate: "const") != nil)
        #expect(CodeCompletionFilter.match(query: "con", candidate: "CONST") != nil)
    }

    /// An empty query is a real state — ⌃Space on empty space — so it matches
    /// everything rather than rejecting it, and highlights nothing.
    @Test func anEmptyQueryMatchesEverythingAndHighlightsNothing() {
        let match = CodeCompletionFilter.match(query: "", candidate: "const")

        #expect(match?.ranges.isEmpty == true)
        #expect(labels([item("const"), item("convert")], "").count == 2)
    }

    /// The ranges are what gets drawn bold in the row, so they have to be the
    /// characters that actually matched — and consecutive ones come back
    /// coalesced, because three one-character ranges and one three-character
    /// range draw the same and only one of them is worth reading.
    @Test func matchedRangesLandOnTheCharactersThatMatched() {
        #expect(
            CodeCompletionFilter.match(query: "con", candidate: "console")?.ranges
                == [NSRange(location: 0, length: 3)]
        )
        #expect(
            CodeCompletionFilter.match(query: "cv", candidate: "contractVerify")?.ranges
                == [NSRange(location: 0, length: 1), NSRange(location: 8, length: 1)]
        )
    }

    /// UTF-16 offsets, because the ranges are handed to an attributed string.
    /// A label with an astral-plane character in it has to report offsets past
    /// the surrogate pair.
    @Test func matchedRangesAreCountedInUTF16Units() {
        #expect(
            CodeCompletionFilter.match(query: "ps", candidate: "prefix🎉Suffix")?.ranges
                == [NSRange(location: 0, length: 1), NSRange(location: 8, length: 1)]
        )
    }

    // MARK: - The orderings that matter

    /// The plain case, and the one everybody notices first. All five of these
    /// match `con` as a case-exact prefix and therefore score identically, so
    /// this is really a test of the tie-breaks: the shortest label wins, then the
    /// label itself.
    ///
    /// It regresses a real defect. Implementing LSP's "a missing `sortText`
    /// defaults to the label" literally makes the `sortText` tie-break *become*
    /// the label tie-break, the shorter-label rule can never run, and this
    /// answers `console` first.
    @Test func aPlainPrefixPutsTheShortestExactMatchFirst() {
        let pool = ["contractVerify", "console", "const", "convert", "constructor"].map { item($0) }

        #expect(labels(pool, "con") == ["const", "console", "convert", "constructor", "contractVerify"])
    }

    /// The load-bearing one, and the reason a one-character trigger is usable
    /// at all: the `+40` for a match at a word boundary is what makes a
    /// camel-hump query mean what the user meant by it. Greedy leftmost matching
    /// alone would take the lowercase `v` in `convert` and rank the two the
    /// other way round.
    @Test func aCamelHumpQueryPrefersTheWordBoundaryMatch() {
        let pool = ["convert", "contractVerify"].map { item($0) }

        #expect(labels(pool, "cv") == ["contractVerify", "convert"])
    }

    /// The same rule reaching a boundary that greedy matching cannot see: the
    /// `V` of `convertValue` sits behind a lowercase `v` that a leftmost scan
    /// takes first. Trying the boundary-only alignment as well is what finds it.
    @Test func aBoundaryBehindAnEarlierPlainMatchIsStillFound() {
        let pool = ["convert", "convertValue"].map { item($0) }

        #expect(labels(pool, "cv") == ["convertValue", "convert"])
    }

    /// Case-exact beats case-insensitive, which is the difference between
    /// `const` and `Constructor` for `con`.
    @Test func anExactCasePrefixOutranksACaseFoldedOne() {
        let pool = [item("Const"), item("const")]

        #expect(labels(pool, "con") == ["const", "Const"])
    }

    // MARK: - sortText

    /// Equal scores, and the server has an opinion about the order. Both labels
    /// here match through the same `filterText`, so nothing but `sortText`
    /// separates them.
    @Test func equalScoresAreBrokenByTheServersOwnOrdering() {
        let pool = [
            item("second", filterText: "value", sortText: "20"),
            item("first", filterText: "value", sortText: "10"),
        ]

        #expect(labels(pool, "value") == ["first", "second"])
    }

    /// A measured fact about `typescript-language-server`: it prefixes
    /// auto-import items with `U+FFFF` to sink them below everything local. That
    /// only works if the comparison is scalar-wise — a collating compare treats
    /// `U+FFFF` as ignorable and floats the auto-imports straight to the top,
    /// which reads as a ranking bug in this file rather than a comparison bug.
    @Test func aSortTextPrefixedWithTheHighSentinelSinks() {
        let pool = [
            item("autoImported", filterText: "useState", sortText: "\u{FFFF}16"),
            item("local", filterText: "useState", sortText: "11"),
        ]

        #expect(labels(pool, "useState") == ["local", "autoImported"])
    }

    /// And the measured `kotlin-language-server` fact, which the same comparison
    /// protects from the other direction: it orders with a zero-padded index, and
    /// numeric-aware collation reshuffles it.
    @Test func aZeroPaddedSortTextKeepsItsOrder() {
        let pool = [
            item("third", filterText: "x", sortText: "0100"),
            item("first", filterText: "x", sortText: "0002"),
            item("second", filterText: "x", sortText: "0010"),
        ]

        #expect(labels(pool, "x") == ["first", "second", "third"])
    }

    @Test func scalarwiseComparisonIsLexicographicByCodePoint() {
        #expect(CodeCompletionFilter.scalarwise("a", precedes: "\u{FFFF}"))
        #expect(CodeCompletionFilter.scalarwise("0002", precedes: "0010"))
        #expect(CodeCompletionFilter.scalarwise("ab", precedes: "abc"))
        #expect(!CodeCompletionFilter.scalarwise("ab", precedes: "ab"))
        #expect(!CodeCompletionFilter.scalarwise("b", precedes: "a"))
    }

    // MARK: - Preselection

    @Test func preselectionBreaksATieTheServerDidNotOrder() {
        let pool = [
            item("beta", filterText: "x"),
            item("alpha", filterText: "x", isPreselected: true),
        ]

        #expect(labels(pool, "x") == ["alpha", "beta"])
    }

    // MARK: - Sources

    /// The fallback exists so a language with no server installed still
    /// completes — not so it can outrank a server that knows the actual types.
    /// `conx` is a shorter, tighter match than `connectToDatabase` and still
    /// loses, because the handicap is meant to be decisive.
    @Test func aBufferWordLosesToAServerItemItWouldOtherwiseBeat() {
        let pool = [
            item("conx", source: .buffer),
            item("connectToDatabase", kind: .function, source: .server),
        ]

        #expect(labels(pool, "con") == ["connectToDatabase", "conx"])
    }

    /// The complement, so the handicap did not overcorrect into "the fallback is
    /// always last": with no server in the list there is nothing to be second to,
    /// and penalising the fallback against itself would be meaningless.
    @Test func withNoServerItemsTheFallbackIsRankedOnItsMerits() {
        let pool = [
            item("connectToDatabase", source: .buffer),
            item("conx", source: .buffer),
        ]

        #expect(labels(pool, "con") == ["conx", "connectToDatabase"])
    }

    /// The buffer scrape offers back words the server already described, and
    /// two identical rows in a list is worse than either of them alone.
    @Test func aBufferWordWithTheSameLabelAsAServerItemDisappears() {
        let pool = [
            item("connect", kind: .function, source: .buffer),
            item("connect", kind: .function, detail: "(url: string)", source: .server),
        ]
        let ranked = CodeCompletionFilter.rank(pool, query: "con")

        #expect(ranked.count == 1)
        #expect(ranked.first?.source == .server)
        #expect(ranked.first?.detail == "(url: string)")
    }

    /// Deduplication never removes a row the server meant to show, and this is
    /// the case that makes the rule matter rather than a hypothetical.
    ///
    /// `typescript-language-server` offers a symbol that is in scope and the
    /// same symbol from an unimported module as two items with the same label
    /// **and** the same kind — one costing nothing, the other editing the top of
    /// your file. Keying deduplication on `(label, kind)` deletes the
    /// auto-import row, which is the headline case the completion list exists
    /// for. The server's own evidence that it wants both shown is that it sinks
    /// the second with a `U+FFFF` `sortText` rather than omitting it.
    @Test func aLocalSymbolAndItsAutoImportTwinAreBothShown() {
        let pool = [
            item("useState", kind: .function, detail: "./react", sortText: "\u{FFFF}16"),
            item("useState", kind: .function, sortText: "11"),
        ]
        let ranked = CodeCompletionFilter.rank(pool, query: "use")

        #expect(ranked.count == 2)
        #expect(ranked.map(\.detail) == [nil, "./react"], "the local one first, the import below it")
        #expect(ranked[0].id != ranked[1].id, "two rows in one table cannot share an identity")
    }

    /// The same rule at the ordinary scale: a function and a variable of the
    /// same name are two rows.
    @Test func theSameLabelUnderDifferentKindsSurvivesAsTwoRows() {
        let pool = [
            item("value", kind: .function),
            item("value", kind: .variable),
        ]

        #expect(CodeCompletionFilter.rank(pool, query: "val").count == 2)
    }

    /// And the case where collapsing *is* right, so the rule above did not
    /// overcorrect into "nothing is ever deduplicated": two scrapes of the same
    /// identifier are the same string with nothing to tell them apart.
    @Test func twoFallbackRowsForTheSameWordCollapse() {
        let pool = [
            item("total", kind: .text, source: .buffer),
            item("total", kind: .text, source: .buffer),
        ]

        #expect(CodeCompletionFilter.rank(pool, query: "tot").count == 1)
    }

    // MARK: - Determinism

    /// The list is assembled by concatenating sources, and the order they
    /// happen to be concatenated in must not reach the screen. Without a *total*
    /// order this fails intermittently, on a machine other than the one it was
    /// written on, for a reason that has nothing to do with the algorithm.
    @Test func theRankingIsUnchangedByTheOrderTheItemsArriveIn() {
        let pool = [
            item("const"),
            item("console", kind: .function),
            item("convert", kind: .method),
            item("constructor", kind: .type),
            item("contractVerify", kind: .function),
            item("connect", source: .buffer),
        ]
        let expected = CodeCompletionFilter.rank(pool, query: "con").map(\.id)

        #expect(CodeCompletionFilter.rank(Array(pool.reversed()), query: "con").map(\.id) == expected)
        #expect(
            CodeCompletionFilter.rank(Array(pool[3...] + pool[..<3]), query: "con").map(\.id)
                == expected
        )
    }

    /// Rows that tie all the way down to the label still have to come out in a
    /// fixed order, which is what the id is the last resort for.
    @Test func rowsIdenticalDownToTheLabelStillHaveAFixedOrder() {
        let pool = [
            item("value", kind: .variable),
            item("value", kind: .function),
            item("value", kind: .property),
        ]
        let expected = CodeCompletionFilter.rank(pool, query: "value").map(\.id)

        #expect(CodeCompletionFilter.rank(Array(pool.reversed()), query: "value").map(\.id) == expected)
    }

    @Test func rankingAnEmptyListIsEmpty() {
        #expect(CodeCompletionFilter.rank([], query: "con").isEmpty)
    }
}

/// What ranking costs when the list is the size the Tailwind server actually
/// sends.
///
/// Measured against `@tailwindcss/language-server` 0.16.0 in a Tailwind 3
/// project: a completion inside `className="w-"` answers **11,534 items**, and
/// it does not filter by what was typed — it sends the whole universe of
/// variants and utilities every time and expects the client to narrow it. So
/// every keystroke inside a class attribute ranks eleven thousand candidates,
/// which is two orders of magnitude past anything this filter was measured on
/// before.
///
/// **These assert a ratio, not a duration**, and the first version of this file
/// got that wrong: it asserted 60 ms and 90 ms against 27 ms and 43 ms measured
/// here, and CI — a shared runner, with the rest of the suite on it — failed
/// both. A wall-clock budget on a machine you do not own is a coin toss, and
/// this repository already says so about timing tests elsewhere.
///
/// What is worth defending is the *shape*: ranking is linear in the number of
/// candidates, and the failure that would hurt is somebody making it quadratic.
/// Four times the candidates may cost four times as much; sixteen times says
/// the loop grew an inner loop. The reference numbers on this machine, for
/// whoever reads a regression later: 27 ms for `w-` and 43 ms for the empty
/// query, over 11,520 candidates, on the main actor in `showCompletions`.
struct CompletionFilterAtTailwindScaleTests {
    /// Shaped like the real answer: `w-1/2`, `hover:bg-red-500`, `[&>*]:mt-2`
    /// and 15 variants per utility, which is where the volume comes from.
    private static func candidates(variants variantCount: Int) -> [CodeCompletionItem] {
        let utilities = ["w", "h", "p", "m", "px", "py", "mt", "bg", "text", "border", "flex", "grid"]
        let scales = (0..<40).map(String.init) + ["full", "fit", "auto", "px", "1/2", "1/3", "2/3"]
        let variants = ["", "hover:", "focus:", "sm:", "md:", "lg:", "xl:", "dark:", "group-hover:",
                        "peer-focus:", "first:", "last:", "odd:", "even:", "[&>*]:"]

        var items: [CodeCompletionItem] = []
        for variant in variants.prefix(variantCount) {
            for utility in utilities {
                for scale in scales {
                    items.append(CodeCompletionItem(
                        kind: .value,
                        label: "\(variant)\(utility)-\(scale)",
                        detail: "width: 1rem;"
                    ))
                }
            }
        }
        return items
    }

    /// The best of a few runs rather than one, because a shared runner will
    /// occasionally take a scheduling hit in the middle of any single one, and
    /// the fastest run is the one that measured the code instead of the queue.
    private func fastest(_ items: [CodeCompletionItem], query: String) -> Duration {
        let clock = ContinuousClock()
        var best: Duration = .seconds(60)
        for _ in 0..<3 {
            let elapsed = clock.measure { _ = CodeCompletionFilter.rank(items, query: query) }
            best = min(best, elapsed)
        }
        return best
    }

    @Test(arguments: ["w-", ""])
    func rankingGrowsLinearlyWithTheNumberOfCandidates(query: String) {
        let small = Self.candidates(variants: 3)
        let large = Self.candidates(variants: 12)
        #expect(large.count == small.count * 4)

        let one = fastest(small, query: query)
        let four = fastest(large, query: query)

        /// Linear is 4×. The bound is well above that and well below the 16×
        /// an inner loop would cost, so it survives a slow runner and still
        /// catches the thing it is here for.
        #expect(four < one * 8, "4× the candidates cost \(four) against \(one)")
    }

    /// An absolute ceiling as well, generous enough for any machine that could
    /// plausibly run this: past a second the list is not late, it is broken.
    @Test func rankingTheWholeUniverseIsNotUnbounded() {
        let elapsed = fastest(Self.candidates(variants: 15), query: "")
        #expect(elapsed < .seconds(1), "ranking everything took \(elapsed)")
    }

    /// The ordering that makes the volume bearable: what was typed has to come
    /// first, or eleven thousand rows are eleven thousand rows.
    @Test func whatWasTypedComesFirst() {
        let ranked = CodeCompletionFilter.rank(Self.candidates(variants: 15), query: "w-f")
        #expect(ranked.first?.label.hasPrefix("w-f") == true, "got \(ranked.first?.label ?? "nothing")")
    }
}
