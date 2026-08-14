import Foundation

/// The identifiers already in the buffer, for when no server is answering.
///
/// This is the whole of the no-server story, and it is worth more than it
/// sounds: a language with nothing installed still completes the names you
/// wrote thirty lines up, which is most of what completion is used for in
/// practice. What it cannot do is know a type, which is why
/// `CodeCompletionFilter` hands everything from here a flat handicap the moment
/// a real server has something to say.
struct CodeWordIndex {
    /// How far either side of the caret is scanned, in UTF-16 code units.
    ///
    /// Around a hundred kilobytes each way, mirroring the reasoning behind
    /// `CodeTextView`'s whole-document highlighting budget: a full scan on every
    /// keystroke is exactly the cost this editor's architecture exists to avoid,
    /// and the names worth offering are the ones near where you are typing. On a
    /// generated module interface — tens of thousands of lines, which is
    /// precisely where go-to-definition lands — an unbounded scan is the pause
    /// between typing a letter and seeing it.
    static let scanBudget = 100 * 1024

    /// Words in `text` starting with `prefix`, nearest to the caret first.
    ///
    /// `excluding` is the range of the word currently being typed, and it is
    /// taken as a range rather than as a string for a reason: the word under the
    /// caret matches its own prefix perfectly, so without this the list's best
    /// suggestion is always the thing you are halfway through writing. It also
    /// fixes where the caret is, which is what the scan window is centred on.
    ///
    /// Ordering is by distance from the caret, and that matters because of
    /// `limit`: the cap has to fall on the words least likely to be wanted, and
    /// in document order it would fall on the nearest ones instead — the window
    /// starts a hundred kilobytes *above* the caret, so document order hands
    /// back the top of the file first. Ties keep document order, so the result
    /// is fully determined by the text.
    ///
    /// `prefix` is matched case-insensitively and literally. A camel-hump query
    /// like `cv` therefore will not pull `contractVerify` out of the buffer the
    /// way it would out of a server's list — a deliberate cut: this filter is
    /// the cheap bound that keeps a two-hundred-kilobyte window from returning
    /// every identifier in it, and a subsequence test at one character returns
    /// nearly all of them, only to have `limit` truncate the result before
    /// anything has ranked it.
    static func words(
        in text: NSString,
        excluding: NSRange,
        matching prefix: String,
        limit: Int
    ) -> [String] {
        guard limit > 0, let regex = Self.identifiers else { return [] }

        let caret = max(0, min(excluding.location, text.length))
        let start = max(0, caret - scanBudget)
        let end = min(text.length, caret + scanBudget)
        let window = NSRange(location: start, length: max(0, end - start))
        guard window.length > 0 else { return [] }

        let wanted = Array(prefix.utf16).map(folded)
        var seen: Set<String> = []
        var found: [(word: String, distance: Int)] = []

        regex.enumerateMatches(in: text as String, options: [], range: window) { match, _, _ in
            guard let range = match?.range else { return }
            guard NSIntersectionRange(range, excluding).length == 0 else { return }
            guard Self.matches(prefix: wanted, in: text, at: range) else { return }

            let word = text.substring(with: range)
            guard seen.insert(word).inserted else { return }
            found.append((word, abs(range.location - caret)))
        }

        return found
            .enumerated()
            .sorted { ($0.element.distance, $0.offset) < ($1.element.distance, $1.offset) }
            .prefix(limit)
            .map(\.element.word)
    }

    /// Tests the prefix against the buffer in place.
    ///
    /// In place, rather than by making a `String` of the word and asking it,
    /// because the overwhelming majority of the identifiers in a
    /// two-hundred-kilobyte window do not match — and allocating a string for
    /// each of them on every keystroke to find that out is the kind of cost that
    /// only shows up on someone else's machine.
    private static func matches(prefix: [unichar], in text: NSString, at range: NSRange) -> Bool {
        guard range.length >= prefix.count else { return false }
        for (offset, unit) in prefix.enumerated() {
            guard folded(text.character(at: range.location + offset)) == unit else { return false }
        }
        return true
    }

    /// ASCII case folding, matching the character class the pattern below
    /// accepts: nothing it can match needs more than this.
    private static func folded(_ unit: unichar) -> unichar {
        (0x41...0x5A).contains(unit) ? unit + 0x20 : unit
    }

    /// The one shape TypeScript, Go, Swift and Kotlin all agree on.
    ///
    /// ASCII on purpose — every identifier anyone writes in these four is ASCII,
    /// and a Unicode-aware class here would be paying for `\p{L}` matching on a
    /// two-hundred-kilobyte window to gain names nobody types. `$` is in because
    /// JavaScript allows it and made an idiom of it.
    ///
    /// Built once and shared, for the reason `SyntaxHighlighter` states about
    /// its own cache: compiling an `NSRegularExpression` costs far more than
    /// running one, and this runs while you type.
    private static let identifiers = try? NSRegularExpression(
        pattern: "[A-Za-z_$][A-Za-z0-9_$]*",
        options: []
    )
}
