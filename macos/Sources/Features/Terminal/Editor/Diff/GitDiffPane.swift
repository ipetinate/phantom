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
    /// The whole document rather than its rows, for one number: the longest
    /// line, which the document measured once when it was parsed. Computing it
    /// here meant walking every row of a twelve-thousand-line diff on every
    /// render pass.
    let document: GitDiffDocument
    let side: GitDiffPaneSide
    let theme: CodeTheme
    let palette: GitDiffPalette
    let font: NSFont

    /// The link this pane's scrolling joins, and which end of it this is.
    ///
    /// Taken as parameters and applied *inside* the scroll view rather than
    /// left to the caller, because the probe finds its scroll view by
    /// looking outwards: applied to a `GitDiffPane` from the outside it
    /// looks straight past the one in here and finds nothing, and the two
    /// panes drift apart with no error to say why.
    let scrollSync: ScrollSyncLink
    let syncSide: ScrollSyncSide

    /// Called when a reader asks to see what a gap is hiding. Nil while the
    /// whole file is already on screen, which is what takes the affordance
    /// off a row that has nothing left to reveal.
    var onExpandGap: (() -> Void)?

    private var rows: [GitDiffRow] { document.rows }

    /// How wide the widest line makes this pane.
    ///
    /// Computed rather than measured, which a monospaced font makes exact:
    /// every glyph is one advance wide, so the longest line in characters
    /// is the longest line in points. Measuring instead would mean laying
    /// out every row of a twelve-thousand-line diff to find out how wide
    /// the scroll view should be — and `LazyVStack` cannot answer it
    /// either, because the whole point of it is that it has not looked at
    /// the rows below the fold.
    ///
    /// The character count comes from the document, which measured it when it
    /// was parsed. See `GitDiffDocument.widestLeft`.
    private func contentWidth(_ metrics: GitDiffPaneMetrics) -> CGFloat {
        let longest = side == .left ? document.widestLeft : document.widestRight
        return metrics.gutterWidth + 8 + CGFloat(longest) * font.maximumAdvancement.width + 24
    }

    /// Paints no base colour of its own, deliberately.
    ///
    /// The pane joins the editor's arrangement instead of repeating it: the
    /// source's text view and its scroll view both draw no background, and
    /// the host puts a single layer behind the whole pane, so a solid theme
    /// colour and a window blurred through to the desktop each reach a diff
    /// exactly as they reach code. Filling `theme.background` here could
    /// only ever be wrong in one of the two — the theme's colour is opaque,
    /// because the window's opacity lives in the host layer's alpha and not
    /// in the theme, so a translucent window got a solid slab where the diff
    /// was and a seam where it met the source beside it.
    ///
    /// The per-line tints are unaffected: every one of them is an alpha wash
    /// over whatever is behind, which is now the same thing the source pane
    /// sits on.
    var body: some View {
        /// Once per pane, not once per row. Every one of these depends on the
        /// font alone, and `signWidth` measures two strings to get there — so
        /// reading them from inside the row builder measured two strings for
        /// every row the reader scrolled past.
        let metrics = GitDiffPaneMetrics(font: font)

        return GeometryReader { viewport in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row, metrics)
                            .frame(height: metrics.rowHeight)
                    }
                }
                /// Both dimensions are floored at the viewport's, for two
                /// different reasons. The width so a row's tint runs the
                /// full width of the pane rather than stopping where its
                /// text happens to end, which is what makes a short added
                /// line read as a band instead of a ragged smear. The
                /// height because a scroll view with both axes centres
                /// content smaller than itself, and a diff of nine lines
                /// would otherwise float in the middle of the pane.
                .frame(
                    width: max(contentWidth(metrics), viewport.size.width),
                    alignment: .leading
                )
                .frame(minHeight: viewport.size.height, alignment: .top)
                /// The diff is a document, so its bar carries the content
                /// weight — and without this it inherited whatever System
                /// Settings said, which for "always show scroll bars" is the
                /// 15-point legacy bar the rest of the window no longer has.
                .background(alignment: .top) { OverlayScrollers(weight: .content) }
                .synchronizedScroll(scrollSync, as: syncSide)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: GitDiffRow, _ metrics: GitDiffPaneMetrics) -> some View {
        switch row.content {
        case .gap(let header):
            gapRow(header, metrics)

        case .lines(let left, let right, let inline):
            let line = side == .left ? left : right
            let edits = side == .left ? inline?.removed : inline?.added

            if let line {
                lineRow(
                    line,
                    emphasis: edits,
                    tokens: document.highlight.spans(forRow: row.id, side: side),
                    metrics)
            } else {
                /// Filler. The other side has a line here and this one does
                /// not, so the band is drawn empty rather than skipped —
                /// skipping it is what makes two columns drift apart.
                Color(nsColor: theme.foreground.withAlphaComponent(0.04))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func gapRow(_ header: GitDiffHunk.Header, _ metrics: GitDiffPaneMetrics) -> some View {
        let label = HStack(spacing: 0) {
            Text(gapLabel(header))
                .font(Font(font))
                .foregroundStyle(Color(nsColor: palette.gapForeground))
                .padding(.leading, metrics.gutterWidth + metrics.signWidth + 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: palette.gapBackground))

        if let onExpandGap {
            /// The whole row, not a control inside it. The row is already the
            /// thing that says lines are hidden here, so it is the thing to
            /// click — and it is one line tall, which is not enough room for a
            /// button beside a label.
            Button(action: onExpandGap) { label }
                .buttonStyle(.plain)
                .help("Show the whole file")
        } else {
            label
        }
    }

    /// Git's own `@@` line is the honest label here: it says exactly which
    /// lines were skipped, and a reader who wants that detail has nowhere
    /// else to get it.
    /// `+` for a line that arrived, `-` for one that left, and a space for
    /// one that was already there.
    private func sign(of line: GitDiffLine) -> String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "\u{2212}"
        case .context: return " "
        }
    }

    private func signColor(of line: GitDiffLine) -> NSColor {
        switch line.kind {
        case .added: return palette.addedEmphasis
        case .removed: return palette.removedEmphasis
        case .context: return theme.lineNumber
        }
    }

    private func gapLabel(_ header: GitDiffHunk.Header) -> String {
        let start = side == .left ? header.oldStart : header.newStart
        let count = side == .left ? header.oldCount : header.newCount
        return count == 0 ? "⋯" : "⋯ \(start)–\(start + count - 1)"
    }

    private func lineRow(
        _ line: GitDiffLine,
        emphasis: [NSRange]?,
        tokens: [GitDiffHighlight.Span],
        _ metrics: GitDiffPaneMetrics
    ) -> some View {
        HStack(spacing: 0) {
            Text(number(of: line).map(String.init) ?? "")
                .font(Font(font))
                .foregroundStyle(Color(nsColor: theme.lineNumber))
                .frame(width: metrics.gutterWidth, alignment: .trailing)

            /// The sign, between the number and the text.
            ///
            /// The band behind the row already says a line changed, and it is
            /// the thing that fails first: it is a wash of colour, it is the
            /// same colour for a whole run, and it is the part of this that a
            /// reader with a colour vision deficiency gets least from. A
            /// character says which way, per line, without depending on hue.
            ///
            /// The column is there on every row and empty on unchanged ones,
            /// so nothing shifts sideways where a hunk begins.
            Text(sign(of: line))
                .font(Font(font))
                .foregroundStyle(Color(nsColor: signColor(of: line)))
                .frame(width: metrics.signWidth, alignment: .center)
                .padding(.trailing, 4)

            Text(text(of: line, emphasis: emphasis, tokens: tokens))
                .font(Font(font))
                /// The colour of everything the highlighter had no token
                /// for, and of every line of a language it cannot lex.
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

    /// The line, painted in the theme's token colours, with the characters
    /// that actually differ washed a little stronger than the rest of the
    /// band.
    ///
    /// The two marks say different things and the line carries both: the
    /// colour is what the text *is*, the wash is what changed about it. So
    /// the tokens set a foreground and the emphasis sets a background, and
    /// neither takes the other's answer away.
    ///
    /// `displayText` rather than `text`, so a CRLF file does not draw a
    /// stray glyph on every line — the carriage return is still in the
    /// model, which is what lets the two sides differ by only that.
    private func text(
        of line: GitDiffLine,
        emphasis: [NSRange]?,
        tokens: [GitDiffHighlight.Span]
    ) -> AttributedString {
        var attributed = AttributedString(line.displayText)
        let string = line.displayText

        for token in tokens {
            guard let bounds = bounds(of: token.range, in: string, of: attributed) else { continue }
            attributed[bounds].foregroundColor = Color(nsColor: theme.color(for: token.kind))
        }

        guard let emphasis, !emphasis.isEmpty else { return attributed }

        let wash = line.kind == .added ? palette.addedEmphasis : palette.removedEmphasis
        for range in emphasis {
            guard let bounds = bounds(of: range, in: string, of: attributed) else { continue }
            attributed[bounds].backgroundColor = Color(nsColor: wash)
        }

        return attributed
    }

    /// Where a range measured on the display text lands in the attributed
    /// copy of it, or nil when it lands nowhere.
    ///
    /// Nil is a real answer and not a defence: an emphasis span was measured
    /// on `text`, which is one character longer on a CRLF line, so a span
    /// that reached the carriage return would ask for a range past the end
    /// of what is drawn.
    private func bounds(
        of range: NSRange,
        in string: String,
        of attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard let swiftRange = Range(range, in: string),
              let lower = AttributedString.Index(swiftRange.lowerBound, within: attributed),
              let upper = AttributedString.Index(swiftRange.upperBound, within: attributed)
        else { return nil }
        return lower..<upper
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

/// The font-derived measurements a diff pane draws with.
///
/// One value taken once per render, rather than three computed properties read
/// once per row. `signWidth` in particular measures two strings with
/// `NSString.size(withAttributes:)`, and reading it from inside the row builder
/// measured two strings for every row a reader scrolled past — for a number
/// that depends on nothing but the font.
struct GitDiffPaneMetrics {
    /// Uniform, and deliberately not measured per row.
    ///
    /// Diff rows are single lines of monospaced text with no wrapping, so
    /// they are all the same height anyway — and a uniform height is what
    /// lets the two panes stay aligned without either of them asking the
    /// other how tall its content turned out.
    let rowHeight: CGFloat

    /// Wide enough for a five-digit line number, which covers every file
    /// anyone reads and stops the gutter twitching as it scrolls.
    let gutterWidth: CGFloat

    /// Wide enough for either sign at this font, measured rather than guessed:
    /// a `-` and a `+` are not the same width, and the reader can change the
    /// font.
    let signWidth: CGFloat

    init(font: NSFont) {
        rowHeight = ceil(font.ascender - font.descender + font.leading) + 2
        gutterWidth = ceil(font.maximumAdvancement.width * 5) + 12

        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let plus = ("+" as NSString).size(withAttributes: attributes).width
        let minus = ("\u{2212}" as NSString).size(withAttributes: attributes).width
        signWidth = ceil(max(plus, minus)) + 4
    }
}
