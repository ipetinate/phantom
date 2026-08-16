import Foundation

/// The characters that actually differ between the two halves of a changed
/// row.
///
/// A line-level diff says "this line became that line", which on a line
/// where one argument was renamed makes the reader compare eighty
/// characters by eye to find the four that moved. This is the second pass
/// that points at them, and it is the difference between a diff you read
/// and a diff you scan.
///
/// Ranges are UTF-16 offsets, so they go straight into `NSRange` for an
/// `NSAttributedString` or through `Range(_:in:)` for a Swift `String`.
/// They are always placed on grapheme-cluster boundaries — an emoji or a
/// combining accent is highlighted whole or not at all.
struct GitDiffInlineEdits: Equatable {
    /// Spans of the removed line that are not in the added one.
    let removed: [NSRange]

    /// Spans of the added line that are not in the removed one.
    let added: [NSRange]
}

extension GitDiffInlineEdits {
    /// Lines longer than this are not worth tokenizing. Minified bundles
    /// and embedded data URIs run to tens of thousands of characters, and a
    /// quadratic comparison of two of them stalls the pane it was meant to
    /// decorate.
    static let maximumLineLength = 2_000

    /// Ceiling on the comparison itself, in token pairs.
    static let maximumComparisonCells = 40_000

    /// Below this share of shared non-blank characters, the two lines are
    /// not an edit of one another — they are one line replaced by a
    /// different one that happens to share some brackets and commas.
    /// Highlighting those coincidences speckles the row and hides the
    /// signal.
    static let minimumSharedFraction = 0.25

    /// Which characters changed between the two sides of a row.
    ///
    /// - Returns: nil when there is no useful character-level detail to
    ///   draw — the lines are identical, one replaced the other outright,
    ///   or they are too long to compare. A caller that gets nil should
    ///   treat the whole line as changed, which is what the line-level diff
    ///   already said.
    static func between(removed: String, added: String) -> GitDiffInlineEdits? {
        guard removed != added else { return nil }
        guard removed.count <= maximumLineLength, added.count <= maximumLineLength else { return nil }

        let removedTokens = tokenize(removed)
        let addedTokens = tokenize(added)

        // Most edits change the middle of a line and leave both ends alone,
        // so trimming the matching ends first is not only a speed-up: it
        // keeps the comparison off the part of the line nobody is asking
        // about.
        var head = 0
        while head < removedTokens.count, head < addedTokens.count,
              removedTokens[head].text == addedTokens[head].text {
            head += 1
        }

        var tail = 0
        while tail < removedTokens.count - head, tail < addedTokens.count - head,
              removedTokens[removedTokens.count - 1 - tail].text == addedTokens[addedTokens.count - 1 - tail].text {
            tail += 1
        }

        let removedMiddle = Array(removedTokens[head..<(removedTokens.count - tail)])
        let addedMiddle = Array(addedTokens[head..<(addedTokens.count - tail)])

        guard !removedMiddle.isEmpty || !addedMiddle.isEmpty else { return nil }
        guard removedMiddle.count * addedMiddle.count <= maximumComparisonCells else { return nil }

        let matched = longestCommonSubsequence(removedMiddle, addedMiddle)
        let changedRemoved = Set(0..<removedMiddle.count).subtracting(matched.map(\.left))
        let changedAdded = Set(0..<addedMiddle.count).subtracting(matched.map(\.right))

        // Two lines that share nothing but brackets and commas are a
        // replacement, not an edit. Pointing at the coincidences speckles
        // the row and hides the change instead of showing it.
        let shared = sharedCharacters(in: removedTokens, head: head, tail: tail, changed: changedRemoved)
        let shortest = min(nonBlankCount(removed), nonBlankCount(added))
        if shortest > 0, Double(shared) / Double(shortest) < minimumSharedFraction { return nil }

        return GitDiffInlineEdits(
            removed: ranges(of: changedRemoved, in: removedMiddle, of: removed),
            added: ranges(of: changedAdded, in: addedMiddle, of: added)
        )
    }

    // MARK: Tokens

    /// One word, one run of whitespace, or one lone punctuation character.
    private struct Token {
        let text: Substring
        let range: Range<String.Index>
    }

    /// Splits a line the way a reader sees it.
    ///
    /// Word granularity rather than character: a renamed identifier should
    /// light up as one word, not as the three letters inside it that
    /// happened to change. Punctuation stands alone so `foo(a)` → `foo(b)`
    /// highlights `b` and not `(b)`.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex

        while index < text.endIndex {
            let start = index
            let character = text[index]

            if isWordCharacter(character) {
                while index < text.endIndex, isWordCharacter(text[index]) {
                    index = text.index(after: index)
                }
            } else if character.isWhitespace {
                while index < text.endIndex, text[index].isWhitespace {
                    index = text.index(after: index)
                }
            } else {
                index = text.index(after: index)
            }

            tokens.append(Token(text: text[start..<index], range: start..<index))
        }

        return tokens
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    // MARK: Comparison

    /// Standard dynamic-programming LCS over token text.
    ///
    /// Bounded by ``maximumComparisonCells`` before it is ever called, so
    /// the table stays small enough to build outright.
    private static func longestCommonSubsequence(
        _ left: [Token],
        _ right: [Token]
    ) -> [(left: Int, right: Int)] {
        guard !left.isEmpty, !right.isEmpty else { return [] }

        var lengths = [[Int]](repeating: [Int](repeating: 0, count: right.count + 1), count: left.count + 1)
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                lengths[i][j] = left[i].text == right[j].text
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var pairs: [(left: Int, right: Int)] = []
        var i = 0
        var j = 0
        while i < left.count, j < right.count {
            if left[i].text == right[j].text {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// How much of one side survived the comparison unchanged, counted in
    /// characters that are not blank — indentation two lines happen to
    /// share says nothing about whether they are the same line.
    private static func sharedCharacters(
        in tokens: [Token],
        head: Int,
        tail: Int,
        changed: Set<Int>
    ) -> Int {
        var total = 0
        for index in tokens.indices {
            let isTrimmedEnd = index < head || index >= tokens.count - tail
            guard isTrimmedEnd || !changed.contains(index - head) else { continue }
            if !tokens[index].text.allSatisfy(\.isWhitespace) { total += tokens[index].text.count }
        }
        return total
    }

    private static func nonBlankCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }

    // MARK: Ranges

    /// Turns changed token indices into as few spans as possible, so a
    /// changed word and the bracket beside it are drawn as one highlight
    /// rather than two abutting ones.
    private static func ranges(
        of changed: Set<Int>,
        in tokens: [Token],
        of text: String
    ) -> [NSRange] {
        var spans: [NSRange] = []
        var run: Range<String.Index>?

        for index in tokens.indices {
            guard changed.contains(index) else {
                if let current = run { spans.append(NSRange(current, in: text)) }
                run = nil
                continue
            }

            if let current = run {
                run = current.lowerBound..<tokens[index].range.upperBound
            } else {
                run = tokens[index].range
            }
        }

        if let current = run { spans.append(NSRange(current, in: text)) }
        return spans
    }
}
