import Foundation

/// Moving the caret's line — or every line the selection touches — one line up
/// or down, by swapping it with its neighbour.
///
/// Pure for the reason `CodeNewlineIndent` gives: the whole decision is two
/// line ranges and a string built out of them, and every case that breaks a
/// naive implementation is a boundary — the first line, the last line, a file
/// with no terminator at the end. Boundaries are what a test can enumerate and
/// a window cannot.
///
/// Nothing is reindented. Moving a line is not formatting it, and a version
/// that "helpfully" fixed the indentation on the way would rewrite lines the
/// reader only meant to reorder.
struct CodeLineMove {
    enum Direction: Equatable, Sendable {
        case up
        case down
    }

    /// One edit: the range to replace, what goes in its place, and where the
    /// selection lands afterwards.
    ///
    /// The selection travels with the block. Without that the caret would stay
    /// where it was while the text moved out from under it, so a second press
    /// moved a *different* line — which is what makes a move-line command
    /// useless rather than merely imperfect.
    struct Move: Equatable {
        let replacement: NSRange
        let text: String
        let selection: NSRange
    }

    /// Nil when there is no neighbour to trade places with: the first line
    /// cannot go up, and the last cannot go down.
    static func move(in text: NSString, selection: NSRange, direction: Direction) -> Move? {
        let block = blockRange(for: selection, in: text)

        switch direction {
        case .up:
            guard block.location > 0 else { return nil }
            let above = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
            return swap(upper: above, lower: block, moving: .up, selection: selection, in: text)

        case .down:
            /// A block has a line below it exactly when it is terminated. If it
            /// is, either more text follows or the terminator leaves the blank
            /// last line the reader can see — and moving onto *that* is a real
            /// move, since almost every file ends in a newline. If it is not,
            /// the block runs to the end of the text and there is nothing to
            /// trade with, which is also the answer for the blank last line
            /// itself.
            guard !terminator(of: block, in: text).isEmpty else { return nil }
            let below = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            return swap(upper: block, lower: below, moving: .down, selection: selection, in: text)
        }
    }

    /// The full lines the selection covers, terminators included.
    ///
    /// A selection that ends exactly at the start of the next line has not
    /// touched that line — it stopped on the terminator of the one before —
    /// so the last character is dropped before asking. Without this, selecting
    /// one whole line by dragging to the line below moved two.
    private static func blockRange(for selection: NSRange, in text: NSString) -> NSRange {
        var probe = NSRange(
            location: min(selection.location, text.length),
            length: min(selection.length, max(0, text.length - min(selection.location, text.length))))

        if probe.length > 0, isTerminator(text.character(at: NSMaxRange(probe) - 1)) {
            probe.length -= 1
        }
        return text.lineRange(for: probe)
    }

    /// Builds the edit that puts `lower` where `upper` was.
    ///
    /// The two terminators change hands rather than travelling with their
    /// lines, which is what keeps the replacement exactly as long as what it
    /// replaces: the separator between the two lines is always the one that
    /// was already there, and whatever ended the pair still ends it. That
    /// matters most where one of them has no terminator at all — the last line
    /// of a file that does not end in a newline — because then the line that
    /// moves into last place inherits having none.
    private static func swap(
        upper: NSRange,
        lower: NSRange,
        moving direction: Direction,
        selection: NSRange,
        in text: NSString
    ) -> Move {
        let upperTerminator = terminator(of: upper, in: text)
        let lowerTerminator = terminator(of: lower, in: text)
        let upperContent = text.substring(with: shortened(upper, by: upperTerminator.utf16.count))
        let lowerContent = text.substring(with: shortened(lower, by: lowerTerminator.utf16.count))

        let combined = NSRange(location: upper.location, length: upper.length + lower.length)

        /// The same string in both directions — `lower` always ends up first,
        /// and which of the two is the line the reader is on is the only thing
        /// the direction decides.
        let replacement = lowerContent + upperTerminator + upperContent + lowerTerminator

        let block = direction == .up ? lower : upper
        let movedStart = direction == .up
            ? combined.location
            : combined.location + lowerContent.utf16.count + upperTerminator.utf16.count
        let offset = max(0, selection.location - block.location)
        let end = combined.location + replacement.utf16.count
        let location = min(movedStart + offset, end)

        return Move(
            replacement: combined,
            text: replacement,
            selection: NSRange(location: location, length: min(selection.length, end - location)))
    }

    private static func shortened(_ range: NSRange, by count: Int) -> NSRange {
        NSRange(location: range.location, length: max(0, range.length - count))
    }

    /// What ends this line, as the characters that are actually there — so a
    /// `\r\n` file stays a `\r\n` file.
    private static func terminator(of line: NSRange, in text: NSString) -> String {
        guard line.length > 0 else { return "" }
        let last = text.character(at: NSMaxRange(line) - 1)
        guard isTerminator(last) else { return "" }

        let length = last == 0x0A && line.length >= 2 && text.character(at: NSMaxRange(line) - 2) == 0x0D
            ? 2
            : 1
        return text.substring(with: NSRange(location: NSMaxRange(line) - length, length: length))
    }

    private static func isTerminator(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D
    }
}
