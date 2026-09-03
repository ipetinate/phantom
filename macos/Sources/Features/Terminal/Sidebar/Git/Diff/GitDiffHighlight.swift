import Foundation

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
    static func make(for rows: [GitDiffRow], file: GitFileDiff) -> GitDiffHighlight {
        GitDiffHighlight(
            left: spans(in: rows, side: .left, path: file.previousPath ?? file.path),
            right: spans(in: rows, side: .right, path: file.path)
        )
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
        path: String
    ) -> [[Span]] {
        let language = language(forPath: path)
        guard language != .plain else { return [] }

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
