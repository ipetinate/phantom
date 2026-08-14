import Foundation

/// Which rows survive a query, and — much more importantly — in what order.
///
/// The list opens after **one** character, which was chosen on purpose. That
/// choice moves the entire user experience into this file: at one character
/// almost everything matches, so nothing here is about rejection and everything
/// is about the first three rows being right. The word-boundary bonus is the
/// load-bearing part — it is what puts `contractVerify` above `convert` for
/// `cv`, which is the difference between a list you steer with and a list you
/// dismiss.
///
/// Pure, so the ordering can be pinned down by tests without a window
/// anywhere near it. The tests assert **orderings, never scores**: the numbers
/// below will be retuned, and a test that named one would fail on an
/// improvement.
struct CodeCompletionFilter {
    /// A query matched against one candidate.
    ///
    /// `ranges` are UTF-16 offsets into the candidate, coalesced so a run of
    /// consecutive matches is one range — which is both what a drawing pass
    /// wants and what makes "`con` matched the first three characters" a single
    /// assertion instead of three.
    struct Match: Equatable, Sendable {
        let score: Int
        let ranges: [NSRange]
    }

    /// What a match at a word boundary is worth.
    ///
    /// The largest of the positional bonuses, and deliberately so: the boundary
    /// is the thing a human is aiming at when they type `cv` for
    /// `contractVerify`, so it has to outweigh the shorter, denser, earlier
    /// match that `convert` offers.
    private static let boundaryBonus = 40
    private static let consecutiveBonus = 20
    private static let caseSensitivePrefixBonus = 100
    private static let caseInsensitivePrefixBonus = 80
    private static let matchedCharacterBonus = 1

    /// Skipping characters costs, but only up to a point. Past this the penalty
    /// stops growing, because otherwise a genuine acronym match deep in a long
    /// name loses to any short accident — and a long name is exactly where an
    /// acronym is worth typing.
    private static let maximumSkipPenalty = 30

    /// A late first match costs, also up to a point: after ten characters, one
    /// more makes no difference to how the row reads.
    private static let maximumFirstIndexPenalty = 10

    /// What a word scraped out of the buffer, or a bare language keyword, gives
    /// up when the server also answered.
    ///
    /// Flat rather than proportional, and large enough to be decisive: the
    /// fallback exists so a language with no server installed still completes,
    /// not so it can outrank a server that knows the actual types.
    static let sourceHandicap = 30

    // MARK: Matching

    /// Whether the query is a subsequence of the candidate, and how good a one.
    ///
    /// Two alignments are tried and the better-scoring one wins:
    ///
    /// - **the acronym alignment**, which matches every query character at a
    ///   word boundary, and
    /// - **the leftmost alignment**, plain greedy, which is what most queries
    ///   actually are.
    ///
    /// Both, rather than either, and the reason is `cv` against
    /// `convertValue`: greedy takes the lowercase `v` of `convert` at index 3
    /// and never sees the `V` at 7, scoring the row as if the user had aimed at
    /// nothing. Trying the boundary-only alignment as well costs one more pass
    /// over a short string and is what makes the boundary bonus reachable at
    /// all. Where both alignments are possible and score the same the leftmost
    /// one wins — it is the one a reader expects to see highlighted, and
    /// `max(by:)` with a strict `<` keeps the first of equal elements, which is
    /// why it is listed first below.
    ///
    /// Case folding is ASCII-only, on both the comparison and the
    /// lower-to-upper boundary test. Every identifier in the four languages
    /// this editor completes is ASCII; a label that is not still matches, just
    /// case-sensitively, and paying full Unicode case mapping per character on
    /// the keystroke path to change that would be the wrong trade.
    ///
    /// An empty query matches everything with a score of zero and no
    /// highlighted ranges. It is a real state — ⌃Space on empty space — so it
    /// has to match rather than reject, and scoring every candidate identically
    /// leaves the tie-breaks in `rank` to decide the order on their own.
    static func match(query: String, candidate: String) -> Match? {
        let needle = Array(query.utf16)
        let haystack = Array(candidate.utf16)

        guard !needle.isEmpty else { return Match(score: 0, ranges: []) }
        guard needle.count <= haystack.count else { return nil }

        let boundaries = wordBoundaries(in: haystack)
        let leftmost = alignment(needle, in: haystack, boundariesOnly: nil)
        let acronym = alignment(needle, in: haystack, boundariesOnly: boundaries)

        let scored = [leftmost, acronym].compactMap { $0 }.map { positions in
            (positions: positions, score: score(needle, haystack, positions, boundaries))
        }

        guard let best = scored.max(by: { $0.score < $1.score }) else { return nil }
        return Match(score: best.score, ranges: coalesced(best.positions))
    }

    /// Greedy left-to-right subsequence match, optionally restricted to
    /// positions in `boundariesOnly`.
    ///
    /// Nil when the query is not a subsequence of what it was allowed to look
    /// at — which for the restricted pass is the common case and not an error.
    private static func alignment(
        _ needle: [UInt16],
        in haystack: [UInt16],
        boundariesOnly: Set<Int>?
    ) -> [Int]? {
        var positions: [Int] = []
        positions.reserveCapacity(needle.count)

        var cursor = 0
        for unit in needle {
            let wanted = folded(unit)
            var found: Int?
            var index = cursor
            while index < haystack.count {
                let allowed = boundariesOnly?.contains(index) ?? true
                if allowed, folded(haystack[index]) == wanted {
                    found = index
                    break
                }
                index += 1
            }
            guard let found else { return nil }
            positions.append(found)
            cursor = found + 1
        }
        return positions
    }

    /// The exact formula, applied to an alignment that has already been chosen.
    private static func score(
        _ needle: [UInt16],
        _ haystack: [UInt16],
        _ positions: [Int],
        _ boundaries: Set<Int>
    ) -> Int {
        var total = prefixBonus(needle, haystack)

        for (offset, index) in positions.enumerated() {
            total += matchedCharacterBonus
            if boundaries.contains(index) { total += boundaryBonus }
            if offset > 0, positions[offset - 1] == index - 1 { total += consecutiveBonus }
        }

        if let first = positions.first, let last = positions.last {
            let skipped = (last - first + 1) - positions.count
            total -= min(skipped, maximumSkipPenalty)
            total -= min(first, maximumFirstIndexPenalty)
        }
        return total
    }

    /// A prefix is worth more than any arrangement of scattered matches,
    /// because it is the one case where the user has typed the beginning of the
    /// thing they want and nothing else can be a better guess. Matching case as
    /// well is worth more again — it is the difference between `const` and
    /// `Constructor` for `con`.
    private static func prefixBonus(_ needle: [UInt16], _ haystack: [UInt16]) -> Int {
        var isExact = true
        for (offset, unit) in needle.enumerated() {
            guard folded(haystack[offset]) == folded(unit) else { return 0 }
            if haystack[offset] != unit { isExact = false }
        }
        return isExact ? caseSensitivePrefixBonus : caseInsensitivePrefixBonus
    }

    /// Index 0, anything after `_`, `-`, `.` or `$`, and every lower-to-upper
    /// transition.
    ///
    /// Those four separators rather than a general punctuation class because
    /// they are the ones that actually appear inside a single identifier —
    /// `snake_case`, `kebab-case`, a qualified `foo.bar`, and jQuery's `$`.
    private static func wordBoundaries(in haystack: [UInt16]) -> Set<Int> {
        var result: Set<Int> = haystack.isEmpty ? [] : [0]
        for index in 1..<max(haystack.count, 1) {
            let previous = haystack[index - 1]
            let current = haystack[index]
            if isSeparator(previous) || (isLowerASCII(previous) && isUpperASCII(current)) {
                result.insert(index)
            }
        }
        return result
    }

    private static func isSeparator(_ unit: UInt16) -> Bool {
        unit == 0x5F || unit == 0x2D || unit == 0x2E || unit == 0x24
    }

    private static func isUpperASCII(_ unit: UInt16) -> Bool { (0x41...0x5A).contains(unit) }
    private static func isLowerASCII(_ unit: UInt16) -> Bool { (0x61...0x7A).contains(unit) }

    private static func folded(_ unit: UInt16) -> UInt16 {
        isUpperASCII(unit) ? unit + 0x20 : unit
    }

    /// Adjacent matched indices become one range.
    private static func coalesced(_ positions: [Int]) -> [NSRange] {
        var result: [NSRange] = []
        for index in positions {
            if var last = result.last, last.location + last.length == index {
                last.length += 1
                result[result.count - 1] = last
            } else {
                result.append(NSRange(location: index, length: 1))
            }
        }
        return result
    }

    // MARK: Ranking

    /// Filters, deduplicates and orders a list for one query.
    ///
    /// The handicap and the deduplication both exist to protect the same thing:
    /// a real symbol from a server must never lose to a word that happens to
    /// appear in the file. The handicap applies **only when a server answered**
    /// — with no server the fallback is all there is, and penalising it against
    /// itself would be meaningless.
    ///
    /// Neither of them is allowed to remove a row the server meant to show. See
    /// `deduplicated` for why that sentence had to be written down.
    static func rank(_ items: [CodeCompletionItem], query: String) -> [CodeCompletionItem] {
        let hasServerItems = items.contains { $0.source == .server }

        var scored: [Scored] = []
        scored.reserveCapacity(items.count)
        for item in items {
            guard let match = match(query: query, candidate: item.matchText) else { continue }
            let handicap = (hasServerItems && item.source != .server) ? sourceHandicap : 0
            scored.append(Scored(item: item, score: match.score - handicap))
        }

        return deduplicated(scored)
            .sorted { precedes($0, $1) }
            .map(\.item)
    }

    /// An item with the score it earned for the query being ranked.
    private struct Scored {
        let item: CodeCompletionItem
        let score: Int
    }

    /// Drops the cheap rows a server already covered, and **nothing else**.
    ///
    /// **Two `.server` rows are never collapsed, whatever they share.** That is
    /// the rule to be careful with, because `(label, kind)` looks like a
    /// duplicate key and is not one. `typescript-language-server` offers a
    /// symbol that is in scope and the same symbol from a module you have not
    /// imported as two items with the same label *and* the same kind — a local
    /// `useState` and `useState` from `react`. They are different things: one
    /// costs nothing, the other edits the top of your file. What tells them
    /// apart is the detail column, which is exactly what `detail` exists for,
    /// and the server's own evidence that it wants both shown is that it goes
    /// to the trouble of sinking the second with a `U+FFFF` `sortText` instead
    /// of simply omitting it. Keying on `(label, kind)` here deletes the row a
    /// completion list is *for*.
    ///
    /// What is genuinely redundant is the fallback offering back a word the
    /// server already described. A `.buffer` or `.keyword` row is dropped when
    /// a `.server` row has the same `(label, kind)`; among themselves those
    /// rows collapse too, because two scrapes of the same identifier are the
    /// same string with nothing to tell them apart.
    ///
    /// Where a survivor does have to be picked it is picked by the same total
    /// order the list is displayed in, never by input position — which is what
    /// lets `rank` be asserted stable under permutation.
    private static func deduplicated(_ scored: [Scored]) -> [Scored] {
        var fromServer: [Scored] = []
        var serverKeys: Set<String> = []
        for entry in scored where entry.item.source == .server {
            fromServer.append(entry)
            serverKeys.insert(key(for: entry.item))
        }

        var fallback: [String: Scored] = [:]
        for entry in scored where entry.item.source != .server {
            let key = key(for: entry.item)
            guard !serverKeys.contains(key) else { continue }
            if let incumbent = fallback[key], !precedes(entry, incumbent) { continue }
            fallback[key] = entry
        }

        return fromServer + fallback.values
    }

    private static func key(for item: CodeCompletionItem) -> String {
        "\(item.kind.rawValue)\u{1}\(item.label)"
    }

    /// The display order, and it is a **total** order on purpose.
    ///
    /// Score first, then the server's own `sortText`, then preselection, then
    /// the shorter label, then the label itself — and finally the id, which is
    /// an arbitrary but stable last resort. Without that last step two rows
    /// that tie all the way down would come out in whatever order the sort
    /// happened to leave them, and a test asserting the ordering would fail
    /// intermittently for a reason that has nothing to do with the algorithm.
    ///
    /// **`sortText` is compared only when both rows have one**, and this is the
    /// step that is easiest to get subtly wrong. LSP says a missing `sortText`
    /// defaults to the label, and implementing that literally collapses
    /// everything below it: "sortText ascending" becomes "label ascending", the
    /// shorter-label rule can never be reached, and `con` answers `console`
    /// before `const` — which is not an ordering anybody would defend. A row
    /// with no `sortText` has no opinion about where it goes, so the rows that
    /// do keep theirs relative to each other and the rest fall through to the
    /// rules that follow.
    private static func precedes(_ lhs: Scored, _ rhs: Scored) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }

        if let leftKey = lhs.item.sortText, let rightKey = rhs.item.sortText, leftKey != rightKey {
            return scalarwise(leftKey, precedes: rightKey)
        }

        if lhs.item.isPreselected != rhs.item.isPreselected { return lhs.item.isPreselected }
        if lhs.item.label.count != rhs.item.label.count {
            return lhs.item.label.count < rhs.item.label.count
        }
        if lhs.item.label != rhs.item.label {
            return scalarwise(lhs.item.label, precedes: rhs.item.label)
        }
        return scalarwise(lhs.item.id, precedes: rhs.item.id)
    }

    /// Lexicographic by Unicode scalar value, and **never**
    /// `localizedStandardCompare`.
    ///
    /// Both of the servers measured here use `sortText` as a channel that
    /// locale collation destroys: `typescript-language-server` prefixes
    /// auto-import items with `U+FFFF` so they sink below everything local, and
    /// `kotlin-language-server` emits a zero-padded index. A collating compare
    /// treats `U+FFFF` as ignorable and reorders zero-padded numbers by
    /// numeric value, so the auto-imports float to the top and Kotlin's
    /// carefully ordered list is shuffled — both silently, and both looking
    /// like a ranking bug in this file rather than a comparison bug.
    ///
    /// Swift's own `String` comparison is not this either: it normalises first,
    /// which is one more transformation between what the server said and what
    /// gets compared.
    static func scalarwise(_ lhs: String, precedes rhs: String) -> Bool {
        var left = lhs.unicodeScalars.makeIterator()
        var right = rhs.unicodeScalars.makeIterator()

        while true {
            switch (left.next(), right.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (leftScalar?, rightScalar?):
                if leftScalar.value != rightScalar.value {
                    return leftScalar.value < rightScalar.value
                }
            }
        }
    }
}
