import Foundation

/// The character that separates one field from the next.
///
/// Three candidates, because those are the three a CSV in the wild is
/// actually written with: the comma the format is named after, the semicolon
/// every spreadsheet exports instead in a locale that spells a decimal with a
/// comma, and the tab that anything pasted out of a database query uses.
/// Pipes and fixed-width columns exist and are deliberately absent — every
/// extra candidate makes the guess below less certain, and neither of those
/// has a tool behind it that produces them by default.
///
/// The raw value is the **byte**, because that is how the scanner compares
/// it. Every delimiter, quote and line break CSV can carry is ASCII, so the
/// whole parse runs over UTF-8 bytes and only ever decodes the bytes it is
/// going to keep.
enum CSVDelimiter: UInt8, CaseIterable, Equatable, Sendable {
    case comma = 0x2C
    case semicolon = 0x3B
    case tab = 0x09

    var character: Character {
        switch self {
        case .comma: ","
        case .semicolon: ";"
        case .tab: "\t"
        }
    }
}

/// A delimited file, read as a header and its rows.
///
/// Pure, and the reason the whole feature is testable: every case below is a
/// decision about somebody's real export, and none of them needs a window to
/// prove. The view on top of this holds no parsing of its own.
///
/// **What it handles.** Quoted fields; `""` as an escaped quote inside one;
/// delimiters, line breaks and stray quotes inside a quoted field; `\r\n`,
/// `\n` and a lone `\r` as line breaks; a trailing newline, which does not
/// become an extra row; a UTF-8 byte-order mark, which would otherwise end up
/// glued to the first column's name; records with fewer or more fields than
/// the header; and an unterminated quote at end of file.
///
/// **What it deliberately does not.** It never trims a field: a leading space
/// in `a; b` is data, and a parser that decides otherwise cannot be argued
/// with. It has no notion of a type — every cell is the text that was
/// written, and nothing here parses a number or a date. It does not honour a
/// `sep=;` preamble, which is an Excel extension rather than a CSV one, and
/// would read as a one-field first record.
struct CSVTable: Equatable, Sendable {
    /// The first record, which is taken as the header without asking whether
    /// it looks like one.
    ///
    /// Guessing "this file has no header" from the shape of the first row is
    /// a coin flip that costs the reader a row when it loses, and the row is
    /// still legible sitting in the header — a missing one is not.
    ///
    /// Padded with empty names when some row carries more fields than the
    /// header does. An empty name is the honest answer there: the column
    /// exists in the data and was never named, and inventing `Column 21`
    /// would put something in the model that is not in the file.
    let columns: [String]

    /// Every record after the first, each **exactly `columns.count` long**.
    ///
    /// The padding is what makes this a table rather than a list of records
    /// of assorted lengths, and it loses nothing a table could have shown:
    /// no grid can draw the difference between a field that was empty and a
    /// field that was absent. It also means the view indexes a row by column
    /// without a bounds check on every cell, which at twenty columns and
    /// tens of thousands of rows is not nothing.
    let rows: [[String]]

    static let empty = CSVTable(columns: [], rows: [])

    /// No records at all — an empty file, or one holding only blank lines.
    var isEmpty: Bool { columns.isEmpty }

    static func parse(_ text: String) -> CSVTable {
        let bytes = content(of: text)
        guard !bytes.isEmpty else { return .empty }

        let records = records(in: bytes, delimiter: sniff(bytes).rawValue)
        guard let header = records.first else { return .empty }

        let body = records.dropFirst()
        let width = body.reduce(header.count) { max($0, $1.count) }

        return CSVTable(
            columns: padded(header, to: width),
            rows: body.map { padded($0, to: width) }
        )
    }

    /// Which delimiter a file is written with.
    ///
    /// Exposed because it is the guess most likely to be wrong, and the one
    /// whose failure is loudest: a semicolon file read as comma-delimited
    /// draws as a single column of full lines, which is not a broken table
    /// but a table that silently isn't one.
    static func delimiter(sniffedFrom text: String) -> CSVDelimiter {
        sniff(content(of: text))
    }

    /// How much of the file the sniff reads.
    ///
    /// A prefix, cut back to a record boundary, because the answer is the
    /// same after twenty records as after eighty thousand and this runs
    /// before the parse that has to read the rest anyway.
    private static let sniffBytes = 64 * 1024
    private static let sniffRecords = 20

    private static let quote: UInt8 = 0x22
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The file's bytes with a byte-order mark taken off the front.
    ///
    /// Excel writes one on every CSV it exports, and left in place it is not
    /// a rendering artefact but a *data* one: the mark is a legal character,
    /// so the first column is named `\u{FEFF}id` and never matches `id`
    /// again. A slice rather than a fresh array so a ten-megabyte file is not
    /// copied to drop three bytes.
    private static func content(of text: String) -> ArraySlice<UInt8> {
        let bytes = Array(text.utf8)
        return bytes.starts(with: byteOrderMark) ? bytes.dropFirst(byteOrderMark.count) : bytes[...]
    }

    /// The candidate that splits the sample into the most consistent rows.
    ///
    /// Consistency first and field count second, in that order, because that
    /// is the way round that survives the case this exists for. A pt-BR
    /// export of eight semicolon-separated columns is full of decimal commas,
    /// so the comma candidate finds *more* fields than the semicolon one —
    /// and finds a different number of them on every row, because the number
    /// of commas is a property of the values rather than of the format. The
    /// delimiter that describes a file is the one every record agrees about.
    ///
    /// A candidate that yields a single field is rejected outright rather
    /// than scored: one field per record is unanimous agreement about
    /// nothing, and it is exactly the answer that draws the file as one giant
    /// column. When every candidate is rejected the file really does have one
    /// column, and the comma default draws it as one.
    private static func sniff(_ bytes: ArraySlice<UInt8>) -> CSVDelimiter {
        let sample = sniffSample(bytes)

        var best = CSVDelimiter.comma
        var bestAgreement = 0
        var bestFields = 0

        for candidate in CSVDelimiter.allCases {
            let records = records(in: sample, delimiter: candidate.rawValue, limit: sniffRecords)
            guard let header = records.first, header.count > 1 else { continue }

            let agreement = records.filter { $0.count == header.count }.count
            guard agreement > bestAgreement
                || (agreement == bestAgreement && header.count > bestFields)
            else { continue }

            best = candidate
            bestAgreement = agreement
            bestFields = header.count
        }

        return best
    }

    /// The prefix the sniff scores, ending at a line break.
    ///
    /// Cutting mid-record would hand every candidate a final record short of
    /// its fields, which is a point of disagreement none of them earned.
    private static func sniffSample(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard bytes.count > sniffBytes else { return bytes }

        let head = bytes[bytes.startIndex..<(bytes.startIndex + sniffBytes)]
        guard let lastBreak = head.lastIndex(where: { $0 == lineFeed || $0 == carriageReturn })
        else { return head }
        return head[head.startIndex..<lastBreak]
    }

    /// The whole scan: bytes in, records out.
    ///
    /// One pass, no intermediate split into lines — which is the only way a
    /// line break inside a quoted field can be kept, since a file split on
    /// `\n` first has already lost the record it belonged to.
    private static func records(
        in bytes: ArraySlice<UInt8>,
        delimiter: UInt8,
        limit: Int = .max
    ) -> [[String]] {
        let end = bytes.endIndex
        var index = bytes.startIndex
        var records: [[String]] = []

        while index < end, records.count < limit {
            var fields: [String] = []
            var wasQuoted = false
            var finished = false

            while !finished {
                fields.append(
                    field(in: bytes, from: &index, delimiter: delimiter, wasQuoted: &wasQuoted)
                )

                if index >= end {
                    finished = true
                } else if bytes[index] == delimiter {
                    /// Another field follows — including when the file ends
                    /// right here, which is a trailing empty field and not
                    /// the end of the record.
                    index += 1
                } else {
                    /// `\r\n`, `\n`, or a lone `\r`, which is what a file
                    /// last saved by a classic-Mac tool still uses.
                    if bytes[index] == carriageReturn {
                        index += 1
                        if index < end, bytes[index] == lineFeed { index += 1 }
                    } else {
                        index += 1
                    }
                    finished = true
                }
            }

            /// A blank line is not a row of one empty cell.
            ///
            /// Exports end with one often enough that treating it as data
            /// would put a phantom row at the bottom of most files, and the
            /// reader cannot tell it from a row whose only column is empty
            /// anyway. `""` on a line of its own is a *quoted* empty field,
            /// which somebody wrote on purpose, and it is kept.
            if wasQuoted || fields.count > 1 || !(fields.first ?? "").isEmpty {
                records.append(fields)
            }
        }

        return records
    }

    /// One field, leaving `index` on its terminator or at the end.
    ///
    /// - Parameter wasQuoted: raised when this field was written in quotes,
    ///   so the record can tell an empty line from a line holding `""`.
    private static func field(
        in bytes: ArraySlice<UInt8>,
        from index: inout Int,
        delimiter: UInt8,
        wasQuoted: inout Bool
    ) -> String {
        let end = bytes.endIndex
        guard index < end else { return "" }

        /// The common case, and the reason it is written out separately: an
        /// unquoted field is a slice of the input, so it becomes a `String`
        /// with one copy instead of being accumulated a run at a time.
        guard bytes[index] == quote else {
            let start = index
            skipToTerminator(in: bytes, from: &index, delimiter: delimiter)
            return text(bytes[start..<index])
        }

        wasQuoted = true
        index += 1

        var buffer: [UInt8] = []
        var run = index

        while index < end {
            guard bytes[index] == quote else {
                index += 1
                continue
            }
            /// A doubled quote is one quote of content. Anything else is the
            /// end of the quoted run.
            guard index + 1 < end, bytes[index + 1] == quote else { break }
            buffer.append(contentsOf: bytes[run..<index])
            buffer.append(quote)
            index += 2
            run = index
        }

        buffer.append(contentsOf: bytes[run..<index])
        /// Absent when the quote was never closed, which is a truncated
        /// export rather than something to refuse: the field keeps what was
        /// written and the file still opens.
        if index < end { index += 1 }

        /// Characters between the closing quote and the terminator are
        /// invalid per RFC 4180 and are appended anyway, because real files
        /// carry them — `"Ana" Silva` out of a hand-edited export — and
        /// dropping them would be the parser quietly deleting a name.
        let tail = index
        skipToTerminator(in: bytes, from: &index, delimiter: delimiter)
        if tail < index {
            buffer.append(contentsOf: bytes[tail..<index])
        }

        return text(buffer[...])
    }

    /// A run of bytes as text.
    ///
    /// **Total, not lossy, and the linter's suggestion is the wrong shape
    /// here.** This is not a decode of bytes from disk — the parser is handed
    /// a `String`, so the bytes it walks came from that string's own UTF-8
    /// view and are valid by construction. Every cut is made at an ASCII
    /// byte — a delimiter, a quote, a CR or an LF — so no slice can split a
    /// multi-byte scalar either. `String(bytes:encoding:)` would add an
    /// optional that can never be nil and an error path that can never run.
    ///
    /// Which encoding the file was written in is settled long before this,
    /// where it is read off disk; nothing in the parser detects or guesses
    /// one, and nothing here can mangle a file that arrived intact.
    ///
    /// One function taking one slice type rather than a generic or a pair of
    /// overloads, so the exemption is stated once and every field in the file
    /// goes through a call the optimiser can see straight through.
    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }

    private static func skipToTerminator(
        in bytes: ArraySlice<UInt8>,
        from index: inout Int,
        delimiter: UInt8
    ) {
        let end = bytes.endIndex
        while index < end,
              bytes[index] != delimiter,
              bytes[index] != lineFeed,
              bytes[index] != carriageReturn {
            index += 1
        }
    }

    private static func padded(_ fields: [String], to width: Int) -> [String] {
        guard fields.count < width else { return fields }
        return fields + Array(repeating: "", count: width - fields.count)
    }
}
