import AppKit

/// The table's sizes in points, derived from a column layout and a font.
///
/// Computed rather than measured, which the editor's monospaced font makes
/// exact: one advance per character, so a column's width in characters is its
/// width in points. Measuring instead would mean laying out every cell of
/// eighty thousand rows to find out how wide the scroll view should be — and
/// the lazy stack that draws them could not answer it either, since the whole
/// point of it is that it has not looked below the fold. Same reasoning as
/// `GitDiffPane.contentWidth`, which has the same problem.
///
/// A value of its own, and internal rather than private, so the arithmetic
/// can be checked without a window: a content width that does not account for
/// a column is a table with a column nobody can scroll to.
struct CSVTableMetrics: Equatable {
    /// Breathing room on each side of a cell's text.
    static let cellInset: CGFloat = 8

    /// Between the row numbers and the rule beside them. Wider than a cell's
    /// inset because the gutter is read as a margin rather than as a column.
    static let gutterInset: CGFloat = 12

    static let ruleWidth: CGFloat = 1

    /// Empty space past the last column, so the final cell is not flush
    /// against the end of the scrollable area.
    static let trailingInset: CGFloat = 24

    let rowHeight: CGFloat

    /// Taller than a row, which is most of what makes a header read as one
    /// once it is pinned and the rows are sliding under it.
    let headerHeight: CGFloat

    /// The row numbers plus their margin, up to but not including the rule.
    let gutterWidth: CGFloat

    /// Each column's text box, without its insets.
    let textWidths: [CGFloat]

    let contentWidth: CGFloat

    init(layout: CSVColumnLayout, rowCount: Int, font: NSFont) {
        /// A font with no advance to report would collapse every column to
        /// nothing; the fallback is only ever reached by a broken font, and a
        /// slightly wrong table beats an invisible one.
        let advance = font.maximumAdvancement.width > 0 ? font.maximumAdvancement.width : 7

        /// A little more air than the diff pane gives a line of code. A table
        /// is read *across*, and rows packed at code density make the eye
        /// lose which one it is on halfway to column twenty.
        rowHeight = ceil(font.ascender - font.descender + font.leading) + 4
        headerHeight = rowHeight + 6

        /// Sized for the largest row number the file can show, so the gutter
        /// does not widen as the reader scrolls past row 9999. Two digits
        /// minimum, because a five-row file with a one-character gutter reads
        /// as a cramped mistake.
        let digits = max(String(max(rowCount, 1)).count, 2)
        gutterWidth = ceil(advance * CGFloat(digits)) + Self.gutterInset

        textWidths = layout.widths.map { ceil(advance * CGFloat($0)) }
        contentWidth = textWidths.reduce(
            gutterWidth + Self.ruleWidth + Self.trailingInset
        ) { $0 + $1 + Self.cellInset * 2 }
    }

    /// Clamped rather than trusting the caller, because a column index comes
    /// from a row and a row could in principle be longer than the header the
    /// layout was measured from. A zero-width cell is a cosmetic bug; an
    /// index past the end is a crash while scrolling.
    func textWidth(_ column: Int) -> CGFloat {
        textWidths.indices.contains(column) ? textWidths[column] : 0
    }
}
