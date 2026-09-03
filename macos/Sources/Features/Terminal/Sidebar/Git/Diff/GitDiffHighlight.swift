import Foundation

/// The whole version of a file on each side of a diff, for the colouring
/// pass that cannot work from the hunks alone.
///
/// Nil rather than empty for a side that could not be read: an empty string
/// is a file with no lines, and every row would map onto nothing.
struct GitDiffSource: Equatable {
    /// The old version, matching the diff's left column line for line.
    let old: String?

    /// The new version, matching its right column.
    let new: String?

    /// What every diff got before there was a source, and what the ones that
    /// do not need one still get.
    static let none = GitDiffSource(old: nil, new: nil)
}

/// The syntax colouring for a diff's two sides, worked out once when the
/// document is built.
///
/// Kinds and not colours, so that this is the same answer for every theme:
/// the pane turns a kind into a colour when it draws, and changing the theme
/// repaints without lexing anything again.
///
/// **Not left to the pane, for the reason the widths beside it were taken off
/// the render path.** A card draws rows as the reader scrolls, and a
/// `LazyVStack` builds a row again every time it comes back into view — so a
/// line lexed where it is drawn is a line lexed on every scroll. Here it
/// happens once, off the main actor, where the diff is parsed.
///
/// **Whole sides rather than single lines.** The old version's lines are
/// joined into one document and the new version's into another, because a
/// line alone is not enough to lex: the body of a block comment is only a
/// comment because of a `/*` on an earlier line. The tokens are then cut back
/// up per row, which is how a comment that spans a hunk keeps its colour on
/// every line of it.
///
/// The reconstruction is the diff's own text and not the file's, so the
/// context git left out is missing from it. That costs colour where a
/// construct opened in a hidden line — the whole file is one button away in
/// the row above, and it is the editor's job.
///
/// **Except for a document made of blocks, where the missing context is not
/// a shade of colour but all of it.** ``SFCRegions`` finds a `.vue` file's
/// `<script>`, `<template>` and `<style>` by their tags, so a hunk from the
/// middle of one carries nothing to say which block it is in: it falls
/// outside every region and lexes to nothing, and the card drew flat text
/// until the reader expanded the file far enough to bring a tag into the
/// fragment. Guessing `.javascript` for a tagless fragment is the wrong
/// answer and `SFCRegions` says why — the same bytes are a keyword in one
/// block and an attribute in another. So the whole version of the file is
/// lexed instead and its tokens are mapped onto the diff's lines by line
/// number. ``needsWholeFile(_:)`` names the files that pay for it.
struct GitDiffHighlight: Equatable {
    /// One coloured run inside a single line, in UTF-16 offsets from the
    /// start of that line's `displayText`.
    ///
    /// `displayText` because that is the string the pane draws: a span
    /// measured against `text` would be off by one on every line of a CRLF
    /// file, past the end on the last of them.
    struct Span: Equatable {
        let range: NSRange
        let kind: TokenKind
    }

    /// How much of one side is lexed before the pass gives up.
    ///
    /// The same kind of bound as ``GitDiffAlignment/inlineEditBudget``, and
    /// there for the same reason: the whole-file toggle can hand this a
    /// megabyte of text, one regex pass over that is not free, and nobody
    /// reads a diff that long token by token. Lines past the budget draw the
    /// way every line drew before there was any colouring.
    static let textBudget = 512 * 1024

    private let left: [[Span]]
    private let right: [[Span]]

    /// The spans for one row of one side, or none — which is the answer for
    /// a language this build cannot lex, and the reason such a file still
    /// draws as plain text rather than as nothing.
    func spans(forRow id: Int, side: GitDiffPaneSide) -> [Span] {
        let rows = side == .left ? left : right
        guard rows.indices.contains(id) else { return [] }
        return rows[id]
    }

    /// - Parameter file: for its two paths. A rename can change the language
    ///   — `api.js` renamed to `api.ts` is one diff whose columns are two
    ///   different languages — and the left column is the old file, so it is
    ///   lexed by the name the old file had.
    /// - Parameter source: the whole version of each side, when the loader
    ///   read it. A side with none is lexed from the diff's own text, which
    ///   is what every side was lexed from before.
    static func make(
        for rows: [GitDiffRow],
        file: GitFileDiff,
        source: GitDiffSource = .none
    ) -> GitDiffHighlight {
        GitDiffHighlight(
            left: spans(
                in: rows,
                side: .left,
                path: file.previousPath ?? file.path,
                whole: source.old),
            right: spans(in: rows, side: .right, path: file.path, whole: source.new)
        )
    }

    /// Whether the diff's own text is enough to lex this file, or whether the
    /// loader has to read both versions of it.
    ///
    /// True only for a document made of blocks — `.vue` and `.html`, the two
    /// ``SFCRegions/Container`` cases — and only where the diff is a change
    /// rather than a whole file arriving or leaving. A file added or deleted
    /// has every one of its lines in the hunks already, which is the case a
    /// branch of new work is mostly made of.
    ///
    /// **The cost is two `git show` calls, on a card the reader opened.** A
    /// review holds up to 449 files and loads a diff only when its card
    /// expands, so this is paid per opened `.vue`, off the main actor, in the
    /// same background task that already ran `git diff` and `git log` for
    /// that row.
    static func needsWholeFile(_ file: GitFileDiff) -> Bool {
        guard file.status != .added, file.status != .deleted else { return false }
        return [file.previousPath ?? file.path, file.path].contains {
            SFCRegions.container(of: language(forPath: $0)) != nil
        }
    }

    /// The language a path is drawn in.
    ///
    /// The last component and not the path, because the table that answers
    /// for a name carrying its own language — `Makefile`, `go.mod` — is
    /// matched whole, and `src/go.mod` matches nothing in it.
    static func language(forPath path: String) -> CodeLanguage {
        CodeLanguage.resolve(fileName: (path as NSString).lastPathComponent)
    }

    private static func spans(
        in rows: [GitDiffRow],
        side: GitDiffPaneSide,
        path: String,
        whole: String?
    ) -> [[Span]] {
        let language = language(forPath: path)
        guard language != .plain else { return [] }

        if let whole, !whole.isEmpty, (whole as NSString).length <= textBudget {
            let mapped = spans(in: rows, side: side, language: language, whole: whole)
            /// Empty means the mapping failed rather than that the file has
            /// no tokens — a blob that is not the version the diff was taken
            /// against. The diff's own text is still an answer.
            if !mapped.isEmpty { return mapped }
        }

        return spans(in: rows, side: side, language: language)
    }

    private static func spans(
        in rows: [GitDiffRow],
        side: GitDiffPaneSide,
        language: CodeLanguage
    ) -> [[Span]] {
        let joined = join(rows, side: side)
        guard !joined.lines.isEmpty else { return [] }

        var spans = [[Span]](repeating: [], count: rows.count)
        let tokens = SyntaxHighlighter(language: language).tokens(
            in: joined.text,
            range: NSRange(location: 0, length: (joined.text as NSString).length)
        )
        for token in tokens {
            distribute(token, over: joined.lines, into: &spans)
        }
        return spans
    }

    /// The spans of a diff's lines, read off the whole version of the file.
    ///
    /// Line numbers do the mapping, which is what makes it exact: the numbers
    /// in the diff's own gutter *are* line numbers in this text, so nothing
    /// has to match one string against another to find out where a hunk sits.
    ///
    /// A line whose length disagrees with the row's is dropped rather than
    /// painted. That means the text is not the version the diff was taken
    /// against — a working tree edited between the two commands — and half a
    /// line coloured from one file and half from another reads worse than no
    /// colour at all.
    private static func spans(
        in rows: [GitDiffRow],
        side: GitDiffPaneSide,
        language: CodeLanguage,
        whole text: String
    ) -> [[Span]] {
        var rowByNumber: [Int: (id: Int, length: Int)] = [:]
        for row in rows {
            guard let line = side == .left ? row.left : row.right else { continue }
            guard let number = side == .left ? line.oldNumber : line.newNumber else { continue }
            rowByNumber[number] = (id: row.id, length: line.displayText.utf16.count)
        }
        guard !rowByNumber.isEmpty else { return [] }

        let ns = text as NSString
        var lines: [Line] = []
        var number = 0
        /// `byLines` and not a split on `\n`, for the reason the spans are
        /// measured on `displayText`: the range it reports excludes the line
        /// terminator, so a CRLF file's lines are already the strings the
        /// pane draws.
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, _ in
            number += 1
            guard let row = rowByNumber[number], row.length == range.length else { return }
            lines.append(Line(rowID: row.id, range: range))
        }
        guard !lines.isEmpty else { return [] }

        var spans = [[Span]](repeating: [], count: rows.count)
        let tokens = SyntaxHighlighter(language: language).tokens(
            in: text,
            range: NSRange(location: 0, length: ns.length)
        )
        for token in tokens {
            distribute(token, over: lines, into: &spans)
        }
        return spans
    }

    /// A line of one side, and where it landed in that side's text.
    private struct Line {
        let rowID: Int
        let range: NSRange
    }

    private struct Side {
        let text: String
        let lines: [Line]
    }

    private static func join(_ rows: [GitDiffRow], side: GitDiffPaneSide) -> Side {
        var text = ""
        var lines: [Line] = []
        var offset = 0

        for row in rows {
            guard let line = side == .left ? row.left : row.right else { continue }
            guard offset < textBudget else { break }

            let display = line.displayText
            let length = display.utf16.count
            lines.append(Line(rowID: row.id, range: NSRange(location: offset, length: length)))
            text += display
            text += "\n"
            offset += length + 1
        }

        return Side(text: text, lines: lines)
    }

    /// Cuts one token up along the line boundaries it crosses.
    ///
    /// It crosses them often enough to matter: a block comment, a template
    /// literal and a heredoc are all one token over several lines, and the
    /// pane draws a line at a time.
    private static func distribute(
        _ token: SyntaxHighlighter.Token,
        over lines: [Line],
        into spans: inout [[Span]]
    ) {
        let end = NSMaxRange(token.range)
        var index = firstLine(reaching: token.range.location, in: lines)

        while index < lines.count, lines[index].range.location < end {
            let line = lines[index]
            index += 1

            let clipped = NSIntersectionRange(token.range, line.range)
            guard clipped.length > 0, spans.indices.contains(line.rowID) else { continue }
            spans[line.rowID].append(
                Span(
                    range: NSRange(
                        location: clipped.location - line.range.location,
                        length: clipped.length),
                    kind: token.kind)
            )
        }
    }

    /// The first line whose end is past `offset`, by bisection.
    ///
    /// Bisection rather than a walk from the top: the whole-file toggle
    /// produces thousands of lines and every token would search them all.
    private static func firstLine(reaching offset: Int, in lines: [Line]) -> Int {
        var low = 0
        var high = lines.count

        while low < high {
            let middle = low + (high - low) / 2
            if NSMaxRange(lines[middle].range) <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
