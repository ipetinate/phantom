import Foundation

/// Finds git's conflict markers in a file.
///
/// A state machine over the lines rather than a search for the markers, and
/// that is the whole correctness argument: `=======` is ordinary text in a
/// Markdown heading, a Python banner comment and a changelog, and a parser
/// that looked for separators would report a conflict in half the READMEs
/// ever written. A separator counts only after a `<<<<<<<` has opened a block
/// and before a `>>>>>>>` has closed one.
///
/// A block that never closes is discarded. Git will not leave one, so an
/// unterminated `<<<<<<<` is a file that merely contains the characters —
/// this parser's own documentation, for one — and offering to resolve it
/// would put an action bar over somebody's prose.
enum EditorConflictParser {
    /// Every marker is exactly seven characters, at the very start of a line,
    /// and followed by a space or nothing at all. The last rule is what keeps
    /// `<<<<<<<<` — eight, in a diff of a conflicted file — from opening a
    /// block.
    static let markerLength = 7

    private enum Marker: Character {
        case start = "<"
        case base = "|"
        case separator = "="
        case end = ">"
    }

    /// The label after a marker, or "" — `=======` usually carries none.
    private static func label(_ line: String) -> String {
        String(line.dropFirst(markerLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A line without the carriage return a CRLF file leaves on the end of it.
    ///
    /// Lines are split on `\n` alone, so in a Windows checkout every one of
    /// them still carries a `\r`. Only the marker test needs it gone: a bare
    /// `=======` in such a file is `=======\r`, which is neither empty nor
    /// followed by a space, and without this the separator went unrecognised
    /// and no conflict in the file was ever found. The sections keep theirs,
    /// which is what writes the line endings back unchanged.
    private static func withoutReturn(_ line: String) -> Substring {
        line.hasSuffix("\r") ? line.dropLast() : line[...]
    }

    private static func marker(_ raw: String) -> Marker? {
        let line = withoutReturn(raw)
        guard let first = line.first, let marker = Marker(rawValue: first) else { return nil }
        let run = line.prefix(markerLength)
        guard run.count == markerLength, run.allSatisfy({ $0 == first }) else { return nil }

        /// Exactly seven. An eighth means this is a line *about* markers
        /// rather than a marker, which is what a diff of a conflicted file
        /// looks like when git prefixes every line with its own character.
        let rest = line.dropFirst(markerLength)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return marker
    }

    /// Every complete conflict in `text`, in the order they appear.
    ///
    /// Line splitting is on `\n` alone. A CRLF file keeps its `\r` at the end
    /// of each line, including inside the sections, so a resolution writes the
    /// line endings back exactly as it found them — normalising here would
    /// rewrite every line of a Windows checkout the first time somebody
    /// resolved one conflict in it.
    static func conflicts(in text: String) -> [EditorConflict] {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 2 else { return [] }

        /// Character offsets of the start of every line, so a block's range is
        /// arithmetic rather than a second scan. `utf16` because the range is
        /// handed to `NSTextView`, which counts in UTF-16 — measuring in
        /// characters would land in the wrong place in any file with an emoji
        /// or an accented letter above the conflict.
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }

        var found: [EditorConflict] = []
        var open: Int?
        var separator: Int?
        var baseStart: Int?

        for (index, line) in lines.enumerated() {
            switch marker(line) {
            case .start:
                /// A second `<<<<<<<` before a close abandons the first. Git
                /// does not nest them, so the earlier one was never a
                /// conflict — most likely a line of prose that happened to
                /// open one.
                open = index
                separator = nil
                baseStart = nil

            case .base:
                if open != nil, separator == nil { baseStart = index }

            case .separator:
                if open != nil { separator = index }

            case .end:
                guard let start = open, let middle = separator else { continue }

                let currentEnd = baseStart ?? middle
                let current = Array(lines[(start + 1)..<currentEnd])
                let base = baseStart.map { Array(lines[($0 + 1)..<middle]) }
                let incoming = Array(lines[(middle + 1)..<index])

                /// The block runs to the start of the line *after* the
                /// `>>>>>>>`, which is what pulls its newline in with it.
                /// Unless there is no line after it, in which case the file
                /// ends here and there is no newline to take.
                let isLast = index == lines.count - 1
                let end = isLast
                    ? starts[index] + line.utf16.count
                    : starts[index + 1]

                found.append(EditorConflict(
                    id: found.count,
                    currentLabel: label(lines[start]),
                    incomingLabel: label(line),
                    current: current,
                    base: base,
                    incoming: incoming,
                    startLine: start,
                    endLine: index,
                    range: NSRange(location: starts[start], length: end - starts[start]),
                    endsWithoutNewline: isLast
                ))

                open = nil
                separator = nil
                baseStart = nil

            case nil:
                continue
            }
        }

        return found
    }

    /// Whether `text` holds anything worth parsing.
    ///
    /// A cheap gate for the caller that runs on every keystroke: a file with
    /// no `<<<<<<<` in it anywhere cannot hold a conflict, and finding that
    /// out is one substring search instead of a walk over every line.
    static func mayHoldConflict(_ text: String) -> Bool {
        text.contains("<<<<<<<")
    }
}
