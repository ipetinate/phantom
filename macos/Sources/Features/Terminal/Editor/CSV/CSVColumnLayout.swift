import Foundation

/// Which edge a column's cells sit against.
enum CSVColumnAlignment: Equatable, Sendable {
    case leading
    case trailing
}

/// How wide each column should be drawn, and which way its cells face.
///
/// Pure, and measured in **characters** rather than points, for the same
/// reason the diff pane computes its width instead of measuring it: the
/// editor's font is monospaced, so a count of characters times one advance is
/// exact — and it is the only figure available at all, since the view that
/// needs the width is lazy and has deliberately not looked at the rows below
/// the fold.
///
/// Kept apart from the view so the whole sizing decision can be argued with
/// in a test, and apart from `CSVTable` because it is a *display* opinion:
/// the same file drawn in a wider pane or a different font is the same table.
struct CSVColumnLayout: Equatable, Sendable {
    /// Characters, per column, already clamped.
    let widths: [Int]

    let alignments: [CSVColumnAlignment]

    static let empty = CSVColumnLayout(widths: [], alignments: [])

    /// Narrow enough that a column of `Y`/`N` does not take a thumb's width,
    /// wide enough that it still reads as a column.
    static let minimumWidth = 3

    /// Wide enough for a UUID — which is what the id column of every export
    /// out of a Postgres table holds, and the single most common value that a
    /// tighter cap would cut in half. Past this a cell truncates and carries
    /// its full value as a tooltip: one runaway JSON blob in column nine is
    /// not a reason to push columns ten through twenty off the screen.
    static let maximumWidth = 40

    /// How many rows the measurement is allowed to read.
    ///
    /// Bounded because this runs on the main actor before the first frame,
    /// and the pane's whole promise is that it opens a file of eighty
    /// thousand rows as fast as one of eighty.
    static let sampledRows = 240

    /// The rows the sample reads, **spread across the file** rather than
    /// taken from the top.
    ///
    /// A CSV is very often sorted, and a file sorted ascending puts its
    /// shortest values on the first screen — measured from the top, every
    /// column would be sized for `1` and truncate the rest of the file. A
    /// stride costs exactly the same number of reads and describes the whole
    /// file instead of its opening.
    static func sample(rowCount: Int) -> [Int] {
        let step = max(1, (rowCount + sampledRows - 1) / sampledRows)
        return Array(stride(from: 0, to: rowCount, by: step))
    }

    /// Clamped rather than trusting the caller, for the same reason
    /// `CSVTableMetrics.textWidth(_:)` is: the index arrives from a row, and
    /// a wrongly-aligned cell is a cosmetic bug where an index past the end
    /// is a crash while scrolling.
    func alignment(_ column: Int) -> CSVColumnAlignment {
        alignments.indices.contains(column) ? alignments[column] : .leading
    }

    /// What the sample learns about one column on its way past.
    ///
    /// A struct rather than five parallel arrays, because the alignment rule
    /// reads four of these facts together and an array-per-fact version of it
    /// was already hard to follow at three.
    private struct Scan {
        var width: Int
        var numeric = true
        var populated = false
        var shortest = Int.max
        var longest = 0

        /// Whether any value carried a sign or a separator rather than being
        /// a bare run of digits.
        var punctuated = false

        /// Right-aligned only when place value is actually a thing the reader
        /// can line up — the lengths differ, or a separator or sign is in
        /// there somewhere.
        ///
        /// **The clause that keeps identifiers out**, and it came from the
        /// file this feature was asked for: three of its columns are CNPJs
        /// and one is an eight-digit procedure code, all of fixed width and
        /// all of them nothing but digits. A shape test alone calls those
        /// numbers, and a table that right-aligns a CNPJ next to a name has
        /// said something false about the column for no gain — every value is
        /// the same width, so there is nothing to align. A column of
        /// quantities that happen to be uniform loses nothing by this either,
        /// for exactly the same reason.
        var facesRight: Bool {
            numeric && populated && (shortest != longest || punctuated)
        }
    }

    static func measure(_ table: CSVTable) -> CSVColumnLayout {
        guard !table.columns.isEmpty else { return .empty }

        var scans = table.columns.map { Scan(width: min(max($0.count, minimumWidth), maximumWidth)) }

        for row in sample(rowCount: table.rows.count).lazy.map({ table.rows[$0] }) {
            for column in row.indices where column < scans.count {
                let value = row[column]
                scans[column].width = min(max(scans[column].width, value.count), maximumWidth)

                guard !value.isEmpty else { continue }
                scans[column].populated = true
                scans[column].shortest = min(scans[column].shortest, value.count)
                scans[column].longest = max(scans[column].longest, value.count)

                /// A column is numeric until a sampled cell says otherwise,
                /// and stops being numeric the moment one does — an all-empty
                /// column is not a column of numbers, which is what
                /// `populated` is there to catch.
                if scans[column].numeric, !isNumeric(value) { scans[column].numeric = false }
                if value.contains(where: { !$0.isNumber }) { scans[column].punctuated = true }
            }
        }

        return CSVColumnLayout(
            widths: scans.map(\.width),
            alignments: scans.map { $0.facesRight ? .trailing : .leading }
        )
    }

    /// Whether a cell reads as a number.
    ///
    /// Deliberately about *shape* rather than value: `Double(value)` would
    /// reject `1.234.567,89`, which is how the same spreadsheet that writes
    /// semicolons writes a number, and accept `1e9`, `inf` and `nan`, which
    /// in a CSV are far more likely to be an identifier than a quantity.
    ///
    /// A sign is only a sign at the front, which is what keeps `2025-01-25`
    /// out — a date column right-aligned among its neighbours looks like an
    /// error, and dates are the most common non-number that is all digits and
    /// punctuation. A version string like `1.2.3` does slip through; it is a
    /// cosmetic miss on a column nobody sums.
    static func isNumeric(_ value: String) -> Bool {
        var sawDigit = false

        for (offset, character) in value.enumerated() {
            if character.isASCII, character.isNumber {
                sawDigit = true
                continue
            }
            if character == "." || character == "," { continue }
            if character == "-" || character == "+", offset == 0 { continue }
            return false
        }

        return sawDigit
    }
}
