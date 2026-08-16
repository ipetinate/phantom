import Foundation
@testable import Ghostty
import Testing

/// `ShellCommand.runStreaming` against a real subprocess.
///
/// The point of `runStreaming` over `runResult` is that the caller sees
/// output *as it arrives*, line by line — the LSP install sheet shows the
/// last twelve lines of an install while it runs. A tool that terminates
/// its lines with CRLF used to defeat that completely: every line arrived
/// glued into one string, at flush, after the command had already finished.
/// Nothing failed and nothing was lost, so it looked like a slow installer
/// rather than a bug.
@Suite(.serialized)
struct ShellCommandStreamingTests {
    private func collect(_ script: String) -> (lines: [String], result: ShellCommand.Result) {
        let lock = NSLock()
        var lines: [String] = []
        let result = ShellCommand.runStreaming("/bin/sh", ["-c", script], timeout: 20) { line in
            lock.withLock { lines.append(line) }
        }
        return (lock.withLock { lines }, result)
    }

    /// The exact measurement that found the bug: three CRLF-terminated
    /// lines used to arrive as one.
    @Test func crlfOutputArrivesAsThreeLinesNotOne() {
        let (lines, result) = collect(#"printf 'alpha\r\nbeta\r\ngamma\r\n'"#)

        #expect(result.status == 0)
        #expect(lines == ["alpha", "beta", "gamma"])
    }

    /// The control, so the test above is about CRLF and not about counting.
    @Test func lfOutputStillArrivesAsThreeLines() {
        let (lines, result) = collect(#"printf 'alpha\nbeta\ngamma\n'"#)

        #expect(result.status == 0)
        #expect(lines == ["alpha", "beta", "gamma"])
    }

    /// The `Result` keeps the bytes exactly as the process wrote them. The
    /// per-line normalization is for the callback, and must not quietly
    /// rewrite what a caller reads back in full.
    @Test func theCollectedOutputKeepsTheCarriageReturns() {
        let (_, result) = collect(#"printf 'alpha\r\nbeta\r\n'"#)
        #expect(result.stdout == "alpha\r\nbeta\r\n")
    }

    /// A last line with no terminator at all still arrives, at flush.
    @Test func anUnterminatedFinalLineIsStillDelivered() {
        let (lines, _) = collect(#"printf 'alpha\r\nbeta'"#)
        #expect(lines == ["alpha", "beta"])
    }

    @Test func mixedLineEndingsAreEachDelivered() {
        let (lines, _) = collect(#"printf 'alpha\r\nbeta\ngamma\r\n'"#)
        #expect(lines == ["alpha", "beta", "gamma"])
    }

    /// A bare `\r` is a progress-bar overwrite, not a line break, so the
    /// two halves belong to one line.
    @Test func aBareCarriageReturnDoesNotSplitALine() {
        let (lines, _) = collect(#"printf '50%%\r100%%\n'"#)
        #expect(lines == ["50%\r100%"])
    }

    @Test func stderrIsStreamedToo() {
        let (lines, _) = collect(#"printf 'oops\r\n' >&2"#)
        #expect(lines == ["oops"])
    }
}
