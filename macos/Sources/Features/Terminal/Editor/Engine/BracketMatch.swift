import Foundation

/// The bracket the caret is on, and the one that closes it.
///
/// A different question from the one `BracketDepth` answers. Depth colouring
/// says *how deeply* a bracket is nested, which is what makes a wall of
/// punctuation readable; this says *which other bracket it is*, which is what
/// you want when the block runs off the bottom of the screen. It takes its
/// notion of a bracket from `BracketDepth` rather than keeping a second list.
///
/// Pure on purpose: text in, a caret offset in, a pair of offsets out. The
/// cases that make this feature look broken when they are missed — a caret
/// sitting *after* a closer, a brace inside a string, a document that does
/// not balance — are then arithmetic a test can state, instead of pixels
/// somebody has to notice on screen.
enum BracketMatch {
    /// A matched pair, always one character each and always in document
    /// order: `open` precedes `close` whichever of the two the caret was on.
    struct Pair: Equatable {
        let open: NSRange
        let close: NSRange

        var ranges: [NSRange] { [open, close] }
    }

    /// How far the scan walks before giving up, in characters, each way.
    ///
    /// **Outwards from the caret with a bound, not a pass over the
    /// document.** This runs on every caret move, and in a file the size of a
    /// generated interface — tens of thousands of lines, which is precisely
    /// where go-to-definition lands — a whole-document walk would turn every
    /// arrow key into a walk of a megabyte. A bracket's partner is nearly
    /// always a few hundred characters away: an argument list, a function
    /// body. So the bound buys the common case at full speed and gives up on
    /// the rare one, and giving up shows as no highlight rather than as a
    /// stutter while typing.
    ///
    /// The same size as the padding `CodeTextStorage.invalidationRange` uses,
    /// because the caller has to lex that window to know which brackets are
    /// inside strings, and a window larger than the one recolouring already
    /// pays for would make a caret move more expensive than an edit.
    static let searchLimit = 4096

    /// The pair the caret is on, or `nil`.
    ///
    /// `nil` covers three different situations on purpose: the caret is on no
    /// bracket at all, the bracket it is on has no partner within `limit`, or
    /// what the scan found on the way says the text does not balance. All
    /// three have the same right answer on screen — draw nothing. A highlight
    /// that guesses is worse than none, because it reads as the editor being
    /// certain about something false.
    ///
    /// **The character before the caret is tried first, then the one under
    /// it.** That order is what makes the feature feel right at the moment a
    /// block is finished: typing `}` leaves the caret *past* it, and a rule
    /// that only looked forwards would light nothing exactly then. A first
    /// candidate that turns out to be unmatched does not veto the second, so
    /// a stray closer sitting behind the caret does not blind it to the
    /// opener under it.
    ///
    /// `skipped` is the strings and comments to ignore, the same ranges
    /// `BracketDepth` is given and for the same reason — a brace in `"{"` is
    /// a character in a literal, not an open block. A caret resting on one of
    /// those brackets matches nothing, rather than matching out of the
    /// string into the code around it.
    static func pair(
        in text: NSString,
        caret: Int,
        skipping skipped: [NSRange],
        limit: Int = searchLimit
    ) -> Pair? {
        let sorted = skipped.sorted { $0.location < $1.location }

        for index in [caret - 1, caret] {
            guard index >= 0, index < text.length else { continue }
            guard skip(covering: index, in: sorted) == nil else { continue }

            let character = character(at: index, in: text)

            if BracketDepth.closing[character] != nil {
                if let close = forward(from: index, in: text, skipping: sorted, limit: limit) {
                    return Pair(
                        open: NSRange(location: index, length: 1),
                        close: NSRange(location: close, length: 1)
                    )
                }
            } else if BracketDepth.closers[character] != nil {
                if let open = backward(from: index, in: text, skipping: sorted, limit: limit) {
                    return Pair(
                        open: NSRange(location: open, length: 1),
                        close: NSRange(location: index, length: 1)
                    )
                }
            }
        }

        return nil
    }

    /// Walks right from an opener, keeping a stack of the closers still owed.
    ///
    /// A stack rather than a counter of one bracket kind, and the difference
    /// shows in `([)]`: a counter would pair that `(` with that `)` and draw
    /// a box around two brackets that do not belong to each other. A closer
    /// that does not match the top of the stack means the text is unbalanced,
    /// and the answer to unbalanced text is no pair at all.
    private static func forward(
        from index: Int,
        in text: NSString,
        skipping sorted: [NSRange],
        limit: Int
    ) -> Int? {
        var owed: [Character] = []
        var cursor = index
        let end = min(text.length, index + limit)

        while cursor < end {
            if let skipped = skip(covering: cursor, in: sorted) {
                cursor = NSMaxRange(skipped)
                continue
            }

            let character = character(at: cursor, in: text)
            if let closer = BracketDepth.closing[character] {
                owed.append(closer)
            } else if BracketDepth.closers[character] != nil {
                guard owed.last == character else { return nil }
                owed.removeLast()
                if owed.isEmpty { return cursor }
            }

            cursor += 1
        }

        return nil
    }

    /// The mirror of `forward`, walking left from a closer and owing openers.
    private static func backward(
        from index: Int,
        in text: NSString,
        skipping sorted: [NSRange],
        limit: Int
    ) -> Int? {
        var owed: [Character] = []
        var cursor = index
        let end = max(0, index - limit + 1)

        while cursor >= end {
            if let skipped = skip(covering: cursor, in: sorted) {
                cursor = skipped.location - 1
                continue
            }

            let character = character(at: cursor, in: text)
            if let opener = BracketDepth.closers[character] {
                owed.append(opener)
            } else if BracketDepth.closing[character] != nil {
                guard owed.last == character else { return nil }
                owed.removeLast()
                if owed.isEmpty { return cursor }
            }

            cursor -= 1
        }

        return nil
    }

    /// One UTF-16 unit read as a `Character`, the same way `BracketDepth`
    /// reads it. Safe here and nowhere near general: every bracket is ASCII,
    /// so this can never split a surrogate pair that mattered.
    private static func character(at index: Int, in text: NSString) -> Character {
        Character(UnicodeScalar(text.character(at: index)) ?? " ")
    }

    /// The string or comment covering `index`, if there is one.
    ///
    /// A binary search rather than the forward-only cursor `BracketDepth`
    /// keeps, because this scan runs in both directions and a cursor that
    /// only advances cannot serve the backward one. It relies on the ranges
    /// being sorted and non-overlapping, which is what the highlighter
    /// produces — one regex pass, so no token can start inside another.
    private static func skip(covering index: Int, in sorted: [NSRange]) -> NSRange? {
        var low = 0
        var high = sorted.count - 1

        while low <= high {
            let middle = (low + high) / 2
            let range = sorted[middle]
            if index < range.location {
                high = middle - 1
            } else if index >= NSMaxRange(range) {
                low = middle + 1
            } else {
                return range
            }
        }

        return nil
    }
}
