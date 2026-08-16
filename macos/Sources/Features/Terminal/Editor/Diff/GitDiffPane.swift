import AppKit
import SwiftUI

/// One column of a side-by-side diff — the old version or the new one.
///
/// Both columns are handed the **same** row list. That is what makes the two
/// sides line up: a row whose left is `nil` still occupies a row's height on
/// the left, drawn as filler, so row *n* is at the same offset in both panes
/// and keeping them in step is a matter of matching offsets rather than of
/// mapping one file's line numbers onto the other's.
struct GitDiffPane: View {
    let rows: [GitDiffRow]
    let side: GitDiffPaneSide
    let theme: CodeTheme
    let palette: GitDiffPalette
    let font: NSFont

    /// Uniform, and deliberately not measured per row.
    ///
    /// Diff rows are single lines of monospaced text with no wrapping, so
    /// they are all the same height anyway — and a uniform height is what
    /// lets the two panes stay aligned without either of them asking the
    /// other how tall its content turned out.
    var rowHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 2 }

    /// Wide enough for a five-digit line number, which covers every file
    /// anyone reads and stops the gutter twitching as it scrolls.
    private var gutterWidth: CGFloat { ceil(font.maximumAdvancement.width * 5) + 12 }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    rowView(row)
                        .frame(height: rowHeight)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: theme.background))
    }

    @ViewBuilder
    private func rowView(_ row: GitDiffRow) -> some View {
        switch row.content {
        case .gap(let header):
            gapRow(header)

        case .lines(let left, let right, let inline):
            let line = side == .left ? left : right
            let spans = side == .left ? inline?.removed : inline?.added

            if let line {
                lineRow(line, emphasis: spans)
            } else {
                /// Filler. The other side has a line here and this one does
                /// not, so the band is drawn empty rather than skipped —
                /// skipping it is what makes two columns drift apart.
                Color(nsColor: theme.foreground.withAlphaComponent(0.04))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func gapRow(_ header: GitDiffHunk.Header) -> some View {
        HStack(spacing: 0) {
            Text(gapLabel(header))
                .font(Font(font))
                .foregroundStyle(Color(nsColor: palette.gapForeground))
                .padding(.leading, gutterWidth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: palette.gapBackground))
    }

    /// Git's own `@@` line is the honest label here: it says exactly which
    /// lines were skipped, and a reader who wants that detail has nowhere
    /// else to get it.
    private func gapLabel(_ header: GitDiffHunk.Header) -> String {
        let start = side == .left ? header.oldStart : header.newStart
        let count = side == .left ? header.oldCount : header.newCount
        return count == 0 ? "⋯" : "⋯ \(start)–\(start + count - 1)"
    }

    private func lineRow(_ line: GitDiffLine, emphasis: [NSRange]?) -> some View {
        HStack(spacing: 0) {
            Text(number(of: line).map(String.init) ?? "")
                .font(Font(font))
                .foregroundStyle(Color(nsColor: theme.lineNumber))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 8)

            Text(text(of: line, emphasis: emphasis))
                .font(Font(font))
                .foregroundStyle(Color(nsColor: theme.foreground))
                .fixedSize(horizontal: true, vertical: false)

            if line.isEndOfFileWithoutNewline {
                /// Git reports this as a line of its own; it is a property
                /// of the line above. Drawn as a mark rather than a row so
                /// the two columns keep the same number of rows.
                Text("↵̸")
                    .font(Font(font))
                    .foregroundStyle(Color(nsColor: theme.lineNumber))
                    .padding(.leading, 6)
                    .help("No newline at end of file")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(for: line.kind))
    }

    private func number(of line: GitDiffLine) -> Int? {
        side == .left ? line.oldNumber : line.newNumber
    }

    /// The line, with the characters that actually differ washed a little
    /// stronger than the rest of the band.
    ///
    /// `displayText` rather than `text`, so a CRLF file does not draw a
    /// stray glyph on every line — the carriage return is still in the
    /// model, which is what lets the two sides differ by only that.
    private func text(of line: GitDiffLine, emphasis: [NSRange]?) -> AttributedString {
        var attributed = AttributedString(line.displayText)

        guard let emphasis, !emphasis.isEmpty else { return attributed }

        let wash = line.kind == .added ? palette.addedEmphasis : palette.removedEmphasis
        let string = line.displayText

        for range in emphasis {
            /// Clamped against the *display* text: the ranges were measured
            /// on `text`, which is one character longer on a CRLF line, and
            /// an emphasis span that reached the carriage return would put
            /// the range past the end of what is drawn.
            guard let swiftRange = Range(range, in: string),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: attributed)
            else { continue }

            attributed[lower..<upper].backgroundColor = Color(nsColor: wash)
        }

        return attributed
    }

    private func background(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .context: Color.clear
        case .added: Color(nsColor: palette.addedBackground)
        case .removed: Color(nsColor: palette.removedBackground)
        }
    }
}

/// Which version of the file a pane is showing.
///
/// Its own type rather than `ScrollSyncSide`, because those answer different
/// questions: this one is about old versus new, that one about which pane
/// leads a scroll. They coincide today and would stop coinciding the moment
/// a stacked layout put the new version on top.
enum GitDiffPaneSide: Equatable {
    case left
    case right
}
