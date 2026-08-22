import AppKit
import Foundation
@testable import Ghostty
import Testing

/// How wide each column is drawn, and which way its cells face.
///
/// Both are guesses taken from a bounded sample, which is the only kind of
/// guess a pane that opens an eighty-thousand-row file instantly can make.
/// These pin down what the sample is allowed to cost and what it gets right.
struct CSVColumnLayoutTests {
    private func layout(columns: [String], rows: [[String]]) -> CSVColumnLayout {
        .measure(CSVTable(columns: columns, rows: rows))
    }

    @Test func aColumnIsAtLeastAsWideAsItsOwnName() {
        let measured = layout(columns: ["counter_referral_id"], rows: [["1"]])

        #expect(measured.widths == ["counter_referral_id".count])
    }

    @Test func aColumnIsAsWideAsItsWidestSampledValue() {
        let measured = layout(columns: ["id"], rows: [["1"], ["123456"], ["12"]])

        #expect(measured.widths == [6])
    }

    /// One runaway JSON blob in column nine is not a reason to push columns
    /// ten through twenty off the far edge of the pane.
    @Test func aRunawayValueIsCappedRatherThanTakingTheWholePane() {
        let blob = String(repeating: "x", count: 4_000)
        let measured = layout(columns: ["payload"], rows: [[blob]])

        #expect(measured.widths == [CSVColumnLayout.maximumWidth])
    }

    @Test func aColumnOfSingleCharactersKeepsAMinimumWidth() {
        let measured = layout(columns: ["y"], rows: [["n"], ["y"]])

        #expect(measured.widths == [CSVColumnLayout.minimumWidth])
    }

    /// The whole promise of the pane, stated as arithmetic rather than as a
    /// stopwatch: the measurement reads the same number of rows out of a file
    /// of eighty thousand as out of one of eight hundred.
    @Test func theSampleNeverGrowsWithTheFile() {
        for rowCount in [0, 1, 240, 1_000, 80_000, 5_000_000] {
            let reads = CSVColumnLayout.sample(rowCount: rowCount).count
            #expect(reads <= CSVColumnLayout.sampledRows, "\(rowCount) rows")
            #expect(reads <= rowCount)
        }
    }

    /// Why the sample strides instead of reading the top of the file: a CSV
    /// is very often sorted, and measured from its first screen a file sorted
    /// ascending would size every column for `1`.
    @Test func aWideValueInTheMiddleOfALargeFileStillWidensItsColumn() {
        var rows = (0..<1_000).map { [String($0 % 10)] }
        rows[500] = ["a much longer value"]

        let measured = layout(columns: ["v"], rows: rows)

        #expect(measured.widths == ["a much longer value".count])
    }

    @Test func aColumnOfNumbersOfDifferingLengthsFacesRight() {
        let measured = layout(columns: ["qtd"], rows: [["1"], ["220"], ["3"]])

        #expect(measured.alignments == [.trailing])
    }

    /// The three CNPJ columns and the procedure code out of the file this
    /// feature was asked for: all digits, all the same width, and all
    /// identifiers rather than quantities. Right-aligning them says something
    /// false about the column and buys nothing, because there is no place
    /// value to line up when every value is the same length.
    @Test func aColumnOfFixedWidthDigitsFacesLeftBecauseItIsAnIdentifier() {
        let cnpj = layout(
            columns: ["health_specialist_cnpj"],
            rows: [["13294508000117"], ["18521178000103"], ["13294508000117"]]
        )
        #expect(cnpj.alignments == [.leading])

        let code = layout(columns: ["procedure_code"], rows: [["31602029"], ["31602185"]])
        #expect(code.alignments == [.leading])
    }

    /// The same rule seen from the harmless side: a genuine quantity column
    /// whose values are all one digit is uniform either way, so nothing is
    /// lost by leaving it alone.
    @Test func aColumnOfUniformNumbersFacesLeftAndLosesNothingByIt() {
        #expect(layout(columns: ["quantity"], rows: [["1"], ["2"], ["1"]]).alignments == [.leading])
    }

    /// Dates are the most common thing that is all digits and punctuation and
    /// is not a number. Right-aligned among their neighbours they read as a
    /// mistake.
    @Test func aColumnOfDatesFacesLeft() {
        let measured = layout(columns: ["data_consulta"], rows: [["2025-01-25"], ["2025-02-01"]])

        #expect(measured.alignments == [.leading])
    }

    @Test func aColumnOfUuidsFacesLeft() {
        let measured = layout(
            columns: ["id"],
            rows: [["1e118893-0000-4000-8000-000000000001"]]
        )

        #expect(measured.alignments == [.leading])
    }

    /// An all-empty column has not shown itself to be a column of numbers,
    /// and a blank column drawn right-aligned is a puzzle.
    @Test func anEmptyColumnFacesLeft() {
        #expect(layout(columns: ["x"], rows: [[""], [""]]).alignments == [.leading])
    }

    @Test func aBlankCellDoesNotStopAColumnFromBeingNumeric() {
        #expect(layout(columns: ["n"], rows: [["1"], [""], ["220"]]).alignments == [.trailing])
    }

    @Test func ptBrDecimalsCountAsNumbers() {
        #expect(layout(columns: ["valor"], rows: [["12,50"], ["1.234,00"]]).alignments == [.trailing])
    }

    @Test func whatReadsAsANumberAndWhatDoesNot() {
        for value in ["0", "42", "-7", "+7", "3.14", "12,50", "1.234.567,89"] {
            #expect(CSVColumnLayout.isNumeric(value), "\(value) should read as a number")
        }
        for value in ["", "-", ".", "2025-01-25", "7 units", "1e9", "R$ 5", "N/A", "0x1f"] {
            #expect(!CSVColumnLayout.isNumeric(value), "\(value) should not read as a number")
        }
    }

    @Test func anEmptyTableHasNoLayout() {
        #expect(CSVColumnLayout.measure(.empty) == .empty)
    }

    /// Clamped rather than trapping, because the index arrives from a row and
    /// a crash while scrolling is a far worse outcome than a cell facing the
    /// wrong way.
    @Test func anAlignmentPastTheLastColumnFacesLeft() {
        #expect(layout(columns: ["a"], rows: [["1"]]).alignment(9) == .leading)
    }
}

/// The table's sizes in points — arithmetic over the column layout, because
/// the lazy stack that draws the rows has deliberately not looked at them.
struct CSVTableMetricsTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private func metrics(widths: [Int], rowCount: Int = 100) -> CSVTableMetrics {
        CSVTableMetrics(
            layout: CSVColumnLayout(
                widths: widths,
                alignments: Array(repeating: .leading, count: widths.count)
            ),
            rowCount: rowCount,
            font: font
        )
    }

    /// A content width that does not account for a column is a column nobody
    /// can scroll to.
    @Test func everyColumnFitsInsideTheContentWidth() {
        let measured = metrics(widths: [10, 36, 40, 3, 12])
        let columns = measured.textWidths.reduce(0) { $0 + $1 + CSVTableMetrics.cellInset * 2 }

        #expect(measured.contentWidth >= measured.gutterWidth + columns)
    }

    @Test func aWiderColumnMakesTheContentWider() {
        #expect(metrics(widths: [40]).contentWidth > metrics(widths: [10]).contentWidth)
    }

    @Test func moreColumnsMakeTheContentWider() {
        #expect(metrics(widths: [10, 10]).contentWidth > metrics(widths: [10]).contentWidth)
    }

    /// Sized for the largest row number the file can show, so the gutter does
    /// not widen under the reader as they scroll past row 9999.
    @Test func theGutterIsSizedForTheLargestRowNumber() {
        #expect(metrics(widths: [10], rowCount: 80_000).gutterWidth
            > metrics(widths: [10], rowCount: 80).gutterWidth)
    }

    @Test func aFileOfFiveRowsStillGetsATwoDigitGutter() {
        #expect(metrics(widths: [10], rowCount: 5).gutterWidth
            == metrics(widths: [10], rowCount: 42).gutterWidth)
    }

    /// Most of what makes a pinned header read as a header once the rows are
    /// sliding under it.
    @Test func theHeaderIsTallerThanARow() {
        let measured = metrics(widths: [10])

        #expect(measured.headerHeight > measured.rowHeight)
        #expect(measured.rowHeight > 0)
    }

    @Test func aWidthPastTheLastColumnIsZeroRatherThanACrash() {
        #expect(metrics(widths: [10]).textWidth(9) == 0)
    }

    @Test func anEmptyTableStillHasAGutterAndNoColumns() {
        let measured = metrics(widths: [], rowCount: 0)

        #expect(measured.textWidths.isEmpty)
        #expect(measured.contentWidth > 0)
    }
}
