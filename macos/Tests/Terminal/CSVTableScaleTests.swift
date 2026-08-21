import Foundation
@testable import Ghostty
import Testing

/// What happens to a table the size of a real warehouse export.
///
/// The editor already refuses a text file over `FileOpenGuard.maxBytes`, so
/// ten megabytes is the worst case that can reach the parser at all — around
/// fifty thousand rows at the shape below. Both timing assertions are
/// **ratios**: the absolute cost depends on the machine and on whether the
/// build is optimised, and a budget in milliseconds is a test that fails on a
/// busy runner rather than on a regression.
///
/// The fixtures are `static` so the suite generates each one once. Swift
/// Testing builds a fresh instance per test, and generating six megabytes of
/// text four times over would cost more than everything being measured.
struct CSVTableScaleTests {
    /// Twenty-odd columns, a UUID, a date, and a quoted JSON object with
    /// doubled quotes in it — the shape of the file this feature was asked
    /// for, so the measurement is of the slow path rather than of a toy.
    private static let json = "\"{\"\"state\"\":\"\"RO\"\",\"\"number\"\":\"\"3443242\"\"}\""

    private static let tiny = generated(rows: 800)
    private static let small = generated(rows: 8_000)
    private static let large = generated(rows: 32_000)

    private static func generated(rows: Int) -> String {
        var lines = [
            (["counter_referral_id", "data_consulta", "council", "name"]
                + (1...16).map { "field_\($0)" }).joined(separator: ",")
        ]
        lines.reserveCapacity(rows + 1)

        for index in 0..<rows {
            let fields = [
                "1e118893-0000-4000-8000-\(String(format: "%012d", index))",
                "2025-01-25",
                json,
                "Henrique S",
            ] + (1...16).map { String(index * $0) }
            lines.append(fields.joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    /// The best of several runs rather than an average: the fastest run is the
    /// one least polluted by whatever else the machine was doing.
    private static func fastest(of runs: Int, _ work: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            best = min(best, seconds(ContinuousClock().measure(work)))
        }
        return best
    }

    @Test func aLargeExportParsesIntoTheTableItDescribes() {
        let table = CSVTable.parse(Self.large)

        #expect(table.columns.count == 20)
        #expect(table.rows.count == 32_000)
        #expect(table.rows.last?.first == "1e118893-0000-4000-8000-000000031999")
        #expect(table.rows.last?[2] == "{\"state\":\"RO\",\"number\":\"3443242\"}")
        for row in table.rows.prefix(500) {
            #expect(row.count == 20)
        }
    }

    /// One pass over the bytes, so four times the file should cost about four
    /// times the work. The bound is loose on purpose — what it is here to
    /// catch is a change that makes the parse quadratic, which shows up as a
    /// ratio in the tens rather than as a few percent.
    @Test func parsingCostsAboutWhatTheFileWeighs() {
        _ = CSVTable.parse(Self.small)

        let smallTime = Self.fastest(of: 3) { _ = CSVTable.parse(Self.small) }
        let largeTime = Self.fastest(of: 3) { _ = CSVTable.parse(Self.large) }
        let ratio = largeTime / smallTime

        #expect(ratio < 12, "four times the rows took \(ratio) times as long")
    }

    /// The column measurement reads a bounded sample, so it should cost the
    /// same on a file forty times the size. A ratio near one is the point;
    /// anything approaching forty means the sample stopped being bounded, and
    /// the pane would have started paying for the file's size on every open.
    @Test func measuringColumnsCostsTheSameWhateverTheFileWeighs() {
        let tiny = CSVTable.parse(Self.tiny)
        let large = CSVTable.parse(Self.large)

        _ = CSVColumnLayout.measure(tiny)

        let tinyTime = Self.fastest(of: 7) { _ = CSVColumnLayout.measure(tiny) }
        let largeTime = Self.fastest(of: 7) { _ = CSVColumnLayout.measure(large) }
        let ratio = largeTime / tinyTime

        #expect(ratio < 6, "forty times the rows took \(ratio) times as long to measure")
    }
}
