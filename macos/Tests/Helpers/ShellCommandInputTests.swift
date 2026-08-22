import Foundation
@testable import Ghostty
import Testing

/// Writing to a child's stdin, and telling apart the two ways a command can
/// end without a status.
///
/// Both capabilities exist because the editor formats a buffer that may never
/// have been saved: `prettier --stdin-filepath` is handed the text on stdin
/// and its failures have to be reported as what they were — a formatter that
/// isn't installed says something different to the reader than a formatter
/// that never answered, and `status` is nil for both.
@Suite(.serialized)
struct ShellCommandInputTests {
    @Test func theBufferArrivesOnTheChildsStdin() {
        let result = ShellCommand.runResult("/bin/cat", [], stdin: Data("alpha\nbeta\n".utf8), timeout: 20)

        #expect(result.status == 0)
        #expect(result.stdout == "alpha\nbeta\n")
    }

    /// A buffer larger than a pipe (~64KB) blocks the writer until somebody
    /// reads, and what a filter hands back is about the same size. Writing all
    /// of stdin before draining stdout deadlocks with each side waiting on the
    /// other, and the only symptom is a command that never returns.
    @Test func aBufferLargerThanAPipeDoesNotDeadlock() {
        let text = String(repeating: "let value = 1\n", count: 20_000)
        #expect(text.utf8.count > 200_000)

        let result = ShellCommand.runResult("/bin/cat", [], stdin: Data(text.utf8), timeout: 20)

        #expect(result.status == 0)
        #expect(result.stdout == text)
    }

    /// A child that exits before reading its input leaves us writing into a
    /// closed pipe, and `SIGPIPE`'s default disposition kills the *writer* —
    /// the whole app, for a mistyped flag. If that guard regressed this test
    /// does not fail, it takes the test binary down with it.
    @Test func aChildThatNeverReadsStdinDoesNotTakeTheProcessDown() {
        let text = String(repeating: "let value = 1\n", count: 20_000)
        let result = ShellCommand.runResult("/usr/bin/true", [], stdin: Data(text.utf8), timeout: 20)

        #expect(result.status == 0)
    }

    /// No input means `/dev/null` and not ours: a GUI app's stdin has nothing
    /// a child could read, so a command that reads to EOF has to see one
    /// immediately rather than sit there until the deadline.
    ///
    /// The exit status is the whole assertion, and needs no clock beside it:
    /// a `cat` still waiting on stdin at the deadline is killed, and a killed
    /// run has no status at all.
    @Test func aCommandGivenNoInputSeesAnImmediateEOF() {
        let result = ShellCommand.runResult("/bin/cat", [], timeout: 20)

        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    // MARK: The two ways there is no status

    @Test func aBinaryThatIsNotThereIsALaunchFailure() {
        let result = ShellCommand.runResult("/nonexistent/formatter", [], timeout: 20)

        #expect(result.status == nil)
        #expect(result.launchFailure != nil)
    }

    /// The other nil status, and the reason `launchFailure` is a field rather
    /// than an inference: a command that ran and was killed at the deadline
    /// reports nothing here, so a caller can tell the two apart.
    @Test func aRunKilledAtTheDeadlineIsNotALaunchFailure() {
        let result = ShellCommand.runResult("/bin/sh", ["-c", "sleep 30"], timeout: 0.5)

        #expect(result.status == nil)
        #expect(result.launchFailure == nil)
    }
}
