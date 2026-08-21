import Foundation
@testable import Ghostty
import Testing

/// The parse, which is the half of a CSV table worth being strict about.
///
/// Every case here is somebody's real export. A naive `split(separator: ",")`
/// passes the first two tests and fails every one after them, which is why
/// they are written out one at a time rather than as a single round trip.
struct CSVTableParseTests {
    @Test func aPlainFileBecomesAHeaderAndItsRows() {
        let table = CSVTable.parse("""
        id,name,city
        1,Ana,Recife
        2,Bia,Belém
        """)

        #expect(table.columns == ["id", "name", "city"])
        #expect(table.rows == [["1", "Ana", "Recife"], ["2", "Bia", "Belém"]])
    }

    @Test func aQuotedFieldKeepsItsDelimiter() {
        let table = CSVTable.parse("""
        id,payload
        1,"a,b,c"
        """)

        #expect(table.columns == ["id", "payload"])
        #expect(table.rows == [["1", "a,b,c"]])
    }

    /// Written with escapes rather than as a block literal: the field ends in
    /// three consecutive quotes, which is exactly what a Swift multiline
    /// literal cannot hold.
    @Test func aDoubledQuoteInsideAQuotedFieldIsOneQuote() {
        let table = CSVTable.parse("a\n\"she said \"\"no\"\"\"\n")

        #expect(table.rows == [["she said \"no\""]])
    }

    /// The line from the file this feature was asked for: a JSON object
    /// inside a quoted field, so every one of its own quotes is doubled and
    /// its commas are not delimiters.
    @Test func theJsonObjectInAQuotedFieldSurvivesWhole() {
        let table = CSVTable.parse("""
        counter_referral_id,council,name
        1e118893,"{""state"":""RO"",""number"":""3443242""}",Henrique S
        """)

        #expect(table.columns.count == 3)
        #expect(table.rows == [[
            "1e118893",
            "{\"state\":\"RO\",\"number\":\"3443242\"}",
            "Henrique S",
        ]])
    }

    @Test func aQuotedFieldKeepsALineBreak() {
        let table = CSVTable.parse("""
        name,note
        Ana,"first line
        second line"
        Bia,ok
        """)

        #expect(table.rows.count == 2)
        #expect(table.rows.first == ["Ana", "first line\nsecond line"])
        #expect(table.rows.last == ["Bia", "ok"])
    }

    @Test func crlfEndsARowExactlyAsLfDoes() {
        let table = CSVTable.parse("a,b\r\n1,2\r\n3,4\r\n")

        #expect(table.columns == ["a", "b"])
        #expect(table.rows == [["1", "2"], ["3", "4"]])
    }

    /// A file last written by a classic-Mac tool, and the reason the scanner
    /// treats a lone `\r` as a terminator rather than as content: read as
    /// content it becomes one row holding the whole file.
    @Test func aLoneCarriageReturnEndsARowToo() {
        let table = CSVTable.parse("a,b\r1,2\r3,4")

        #expect(table.rows == [["1", "2"], ["3", "4"]])
    }

    @Test func aTrailingNewlineDoesNotMakeAPhantomRow() {
        #expect(CSVTable.parse("a,b\n1,2\n").rows == [["1", "2"]])
        #expect(CSVTable.parse("a,b\r\n1,2\r\n").rows == [["1", "2"]])
    }

    @Test func aTrailingBlankLineDoesNotMakeAPhantomRowEither() {
        #expect(CSVTable.parse("a,b\n1,2\n\n").rows == [["1", "2"]])
    }

    @Test func blankLinesInTheMiddleAreSkipped() {
        let table = CSVTable.parse("a,b\n\n1,2\n\n\n3,4\n")

        #expect(table.rows == [["1", "2"], ["3", "4"]])
    }

    /// The one blank-looking line that is kept: somebody wrote quotes, so
    /// there is a field there and it is empty on purpose.
    @Test func aQuotedEmptyFieldOnItsOwnLineIsARow() {
        let table = CSVTable.parse("a\n\"\"\n")

        #expect(table.columns == ["a"])
        #expect(table.rows == [[""]])
    }

    @Test func aRowWithFewerFieldsIsPaddedRatherThanDropped() {
        let table = CSVTable.parse("a,b,c\n1,2,3\n4\n")

        #expect(table.rows == [["1", "2", "3"], ["4", "", ""]])
    }

    @Test func aRowWithMoreFieldsWidensTheTableRatherThanLosingThem() {
        let table = CSVTable.parse("a,b\n1,2\n3,4,5\n")

        #expect(table.columns == ["a", "b", ""])
        #expect(table.rows == [["1", "2", ""], ["3", "4", "5"]])
    }

    /// The invariant the view leans on: it indexes a row by column without a
    /// bounds check on every cell.
    @Test func everyRowIsExactlyAsWideAsTheHeader() {
        let table = CSVTable.parse("a,b,c\n1\n1,2\n1,2,3\n1,2,3,4\n1,2,3,4,5\n")

        #expect(table.columns.count == 5)
        for row in table.rows {
            #expect(row.count == table.columns.count)
        }
    }

    @Test func aTrailingDelimiterIsAnEmptyFinalField() {
        let table = CSVTable.parse("a,b,c\n1,2,\n")

        #expect(table.rows == [["1", "2", ""]])
    }

    @Test func emptyFieldsBetweenDelimitersAreKept() {
        let table = CSVTable.parse("a,b,c\n,,\n")

        #expect(table.rows == [["", "", ""]])
    }

    /// A truncated export rather than something to refuse: the field keeps
    /// what was written and the file still opens.
    @Test func anUnterminatedQuoteKeepsWhatWasWritten() {
        let table = CSVTable.parse("a,b\n1,\"unfinished")

        #expect(table.rows == [["1", "unfinished"]])
    }

    /// Invalid per RFC 4180 and kept anyway, because dropping it would be the
    /// parser quietly deleting half of somebody's name.
    @Test func charactersAfterAClosingQuoteAreKept() {
        let table = CSVTable.parse("a\n\"Ana\" Silva\n")

        #expect(table.rows == [["Ana Silva"]])
    }

    @Test func aQuoteInTheMiddleOfAnUnquotedFieldIsLiteral() {
        let table = CSVTable.parse("size,note\n5\" pipe,ok\n")

        #expect(table.rows == [["5\" pipe", "ok"]])
    }

    /// Excel writes a byte-order mark on every CSV it exports. Left in, it is
    /// not a rendering artefact but a data one: the first column is named
    /// `\u{FEFF}id` and never matches `id` again.
    @Test func aByteOrderMarkIsNotPartOfTheFirstColumnName() {
        let table = CSVTable.parse("\u{FEFF}id,name\n1,Ana\n")

        #expect(table.columns == ["id", "name"])
    }

    @Test func fieldsAreNotTrimmed() {
        let table = CSVTable.parse("a; b\n1; 2\n")

        #expect(table.columns == ["a", " b"])
        #expect(table.rows == [["1", " 2"]])
    }

    @Test func nonAsciiTextSurvivesTheByteScanner() {
        let table = CSVTable.parse("nome,cidade\nJoão,São Paulo\n李雷,北京\n")

        #expect(table.rows == [["João", "São Paulo"], ["李雷", "北京"]])
    }

    @Test func anEmptyFileIsAnEmptyTable() {
        #expect(CSVTable.parse("") == .empty)
        #expect(CSVTable.parse("").isEmpty)
    }

    @Test func aFileOfNothingButBlankLinesIsAnEmptyTable() {
        #expect(CSVTable.parse("\n\n\r\n\n").isEmpty)
    }

    @Test func aHeaderWithNoRowsUnderItIsStillAHeader() {
        let table = CSVTable.parse("id,name,city\n")

        #expect(table.columns == ["id", "name", "city"])
        #expect(table.rows.isEmpty)
        #expect(!table.isEmpty)
    }
}

/// Which delimiter a file is written with — the guess whose failure is
/// loudest, because a file read with the wrong one draws as a single column
/// of whole lines rather than as a broken table.
struct CSVDelimiterSniffTests {
    @Test func aCommaFileIsRecognised() {
        #expect(CSVTable.delimiter(sniffedFrom: "a,b,c\n1,2,3\n") == .comma)
    }

    /// The pt-BR case, and the reason agreement is scored before field count:
    /// the comma candidate finds *more* fields here, and a different number of
    /// them on every row, because the commas are decimal points.
    @Test func aSemicolonFileWithDecimalCommasIsNotOneGiantColumn() {
        let text = """
        produto;valor;quantidade
        Café;12,50;3
        Açúcar;4,90;10
        Arroz;22,00;1
        """

        #expect(CSVTable.delimiter(sniffedFrom: text) == .semicolon)

        let table = CSVTable.parse(text)
        #expect(table.columns == ["produto", "valor", "quantidade"])
        #expect(table.rows.count == 3)
    }

    @Test func aTabFileIsRecognised() {
        #expect(CSVTable.delimiter(sniffedFrom: "a\tb\tc\n1\t2\t3\n") == .tab)
    }

    /// Commas inside quotes are content, and the sniff has to see them that
    /// way or it picks the delimiter that appears most often in the data.
    @Test func commasInsideQuotesDoNotDecideTheSniff() {
        let text = """
        "a,b,c,d";x
        "e,f,g,h";y
        """

        #expect(CSVTable.delimiter(sniffedFrom: text) == .semicolon)
        #expect(CSVTable.parse(text).rows == [["e,f,g,h", "y"]])
    }

    /// A file that genuinely has one column: every candidate is rejected, and
    /// the default draws it as the one column it is.
    @Test func aSingleColumnFileFallsBackToComma() {
        #expect(CSVTable.delimiter(sniffedFrom: "only\n1\n2\n") == .comma)
        #expect(CSVTable.parse("only\n1\n2\n").columns == ["only"])
    }

    /// With the same agreement, the candidate that finds more columns wins —
    /// a tie broken towards the reading that shows more of the file. Comma is
    /// scored first here and loses anyway, which is what makes this a test of
    /// the tie-break rather than of the order of the candidates.
    @Test func whenTwoDelimitersAgreeEquallyTheOneFindingMoreColumnsWins() {
        #expect(CSVTable.delimiter(sniffedFrom: "a;b;c,d\n1;2;3,4\n") == .semicolon)
    }

    @Test func anEmptyFileSniffsAsCommaRatherThanCrashing() {
        #expect(CSVTable.delimiter(sniffedFrom: "") == .comma)
    }

    /// The sniff reads a bounded prefix, and this is what that costs and
    /// buys. The first twenty records agree about tabs; the eight thousand
    /// after them agree about commas, and are not read. Reading everything
    /// would make opening a large file pay for a decision that was already
    /// made.
    @Test func theSniffReadsOnlyTheFirstRecords() {
        var lines = ["a\tb,c"]
        lines.append(contentsOf: Array(repeating: "1\t2", count: 19))
        lines.append(contentsOf: Array(repeating: "1,2", count: 8_000))

        #expect(CSVTable.delimiter(sniffedFrom: lines.joined(separator: "\n")) == .tab)
    }
}
