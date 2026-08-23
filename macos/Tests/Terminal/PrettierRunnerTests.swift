import Foundation
@testable import Ghostty
import Testing

/// Running Prettier over a buffer, and — the part that matters — reading what
/// comes back without destroying the file.
///
/// Nothing here needs Prettier installed. The rule that can lose somebody's
/// work is a pure function and is tested as one; the process mechanics are
/// tested against stub scripts written into a temporary directory, which is
/// also the only way to provoke the interesting failures on demand (a child
/// that never exits, a child that exits before reading its input).
struct PrettierRunnerTests {
    // MARK: Reading a finished run

    /// The backstop: empty output is reported as no-change rather than as an
    /// empty result, so no path through this file can blank a buffer.
    ///
    /// Measured against Prettier 3.9.6, the case that reaches here is a
    /// whitespace-only file, where empty is Prettier's genuine answer — so the
    /// rule has a real cost, and this is it: a file of blank lines will not be
    /// emptied. That is the safe direction to be wrong in.
    @Test func emptyOutputOnASuccessfulExitIsNoChange() throws {
        #expect(try PrettierRunner.result(status: 0, stdout: "", stderr: "") == nil)
    }

    /// **The one that deletes files**, and the reason the status is checked
    /// before the emptiness.
    ///
    /// Measured at Prettier 3.9.6: a parse error exits **2 having printed
    /// nothing on stdout**, and so does a file it has no parser for. An
    /// implementation that looked at stdout first would replace the buffer with
    /// nothing every time the reader saved a file with a syntax error in it —
    /// which is to say, halfway through writing any function.
    @Test func aNonZeroExitWithNoOutputIsAFailureAndNotANoChange() {
        do {
            let result = try PrettierRunner.result(status: 1, stdout: "", stderr: "")
            #expect(Bool(false), "expected a failure, got \(String(describing: result))")
        } catch let failure as PrettierFailure {
            #expect(failure == .failed(status: 1, message: "prettier failed without saying why."))
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    /// A single newline is a real answer — the formatted form of a file that
    /// is one blank line. Trimming before the emptiness test would be a second
    /// way to lose content.
    @Test func aSingleNewlineIsNotEmptyOutput() throws {
        #expect(try PrettierRunner.result(status: 0, stdout: "\n", stderr: "") == "\n")
    }

    @Test func formattedTextComesBackVerbatim() throws {
        #expect(try PrettierRunner.result(status: 0, stdout: "const a = 1;\n", stderr: "") == "const a = 1;\n")
    }

    /// Prettier says why it refused on stderr, with a line and a column.
    /// Swallowing it turns "formatting didn't work" into a question nobody can
    /// answer.
    @Test func aFailureSurfacesWhatPrettierSaid() {
        do {
            _ = try PrettierRunner.result(status: 2, stdout: "", stderr: "SyntaxError: Unexpected token (3:1)\n")
            #expect(Bool(false), "expected a failure")
        } catch let failure as PrettierFailure {
            #expect(failure == .failed(status: 2, message: "SyntaxError: Unexpected token (3:1)"))
            #expect(failure.reason == "SyntaxError: Unexpected token (3:1)")
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    /// A broken shim in `node_modules/.bin` complains on stdout instead.
    @Test func aFailureFallsBackToStdout() {
        do {
            _ = try PrettierRunner.result(status: 127, stdout: "env: node: No such file\n", stderr: "")
            #expect(Bool(false), "expected a failure")
        } catch let failure as PrettierFailure {
            #expect(failure == .failed(status: 127, message: "env: node: No such file"))
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    /// No status at all is the deadline having been reached, which is not the
    /// same as exiting non-zero and must not be reported as one.
    @Test func aKilledRunIsATimeoutAndNotAFailure() {
        do {
            _ = try PrettierRunner.result(status: nil, stdout: "", stderr: "", timeout: 4)
            #expect(Bool(false), "expected a failure")
        } catch let failure as PrettierFailure {
            #expect(failure == .timedOut(seconds: 4))
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    // MARK: Against a stub

    @Test func theBufferGoesInOnStdinAndComesBackFromStdout() throws {
        let stub = try makeStub("cat")
        let formatted = try PrettierRunner.format("const a=1;\n", filePath: "/p/main.ts", binary: stub.path)
        #expect(formatted == "const a=1;\n")
    }

    /// The path is how Prettier is told which parser to use and where to
    /// resolve its config from. Losing the flag would make it format
    /// everything as babel, or refuse.
    @Test func theFilePathIsPassedAsStdinFilepath() throws {
        let stub = try makeStub("cat > /dev/null; printf '%s' \"$*\"")
        let formatted = try PrettierRunner.format("x\n", filePath: "/p/src/main.ts", binary: stub.path)
        #expect(formatted == "--stdin-filepath /p/src/main.ts")
    }

    /// The `.prettierignore` case as Prettier actually behaves — measured at
    /// 2.8.8 and 3.9.6, both of which **echo the input back verbatim** and exit
    /// 0 rather than printing nothing. So it arrives as identical text, and it
    /// is `PrettierEdit` that turns it into nothing to do. Asserted through to
    /// that conclusion, because the text coming back unchanged is only safe if
    /// the next layer agrees it is a no-op.
    @Test func anIgnoredFileEchoesTheInputAndEndsAsNoEdit() throws {
        let text = "const a=1;\n"
        let stub = try makeStub("cat")
        let formatted = try PrettierRunner.format(text, filePath: "/p/vendor/main.ts", binary: stub.path)
        #expect(formatted == text)
        #expect(PrettierEdit.minimal(from: text, to: formatted ?? "") == nil)
    }

    /// A child that succeeds while printing nothing, end to end, in case some
    /// future version or plugin does what the folklore says the ignore case
    /// does. Nothing about the buffer changes.
    @Test func aSilentSuccessEndsAsNoChange() throws {
        let stub = try makeStub("cat > /dev/null; exit 0")
        #expect(try PrettierRunner.format("const a=1;\n", filePath: "/p/main.ts", binary: stub.path) == nil)
    }

    /// Prettier's real shape for this: nothing on stdout, the error on stderr
    /// with a line and column, exit 2.
    @Test func aParseErrorArrivesAsAFailureCarryingStderr() throws {
        let stub = try makeStub("cat > /dev/null; echo 'main.ts: SyntaxError: Expression expected. (1:12)' >&2; exit 2")
        do {
            _ = try PrettierRunner.format("(\n", filePath: "/p/main.ts", binary: stub.path)
            #expect(Bool(false), "expected a failure")
        } catch let failure as PrettierFailure {
            #expect(failure == .failed(status: 2, message: "main.ts: SyntaxError: Expression expected. (1:12)"))
        }
    }

    /// A Prettier that hangs — a plugin waiting on something, a watch flag
    /// somebody put in a config — must not hang the save.
    @Test func aRunThatNeverEndsIsKilledAtTheDeadline() throws {
        let stub = try makeStub("sleep 30")
        let started = Date()
        do {
            _ = try PrettierRunner.format("x\n", filePath: "/p/main.ts", binary: stub.path, timeout: 0.5)
            #expect(Bool(false), "expected a timeout")
        } catch let failure as PrettierFailure {
            #expect(failure == .timedOut(seconds: 0.5))
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// A buffer bigger than a pipe (~64KB) blocks the writer until somebody
    /// reads, and the formatted copy coming back is about the same size.
    /// Writing all of stdin before reading stdout deadlocks on any file worth
    /// formatting — both processes waiting on the other, and the only symptom
    /// is that ⌘S never finishes.
    @Test func aBufferLargerThanAPipeDoesNotDeadlock() throws {
        let stub = try makeStub("cat")
        let text = String(repeating: "const value = 1;\n", count: 20_000)
        #expect(text.utf8.count > 300_000)

        let formatted = try PrettierRunner.format(text, filePath: "/p/big.ts", binary: stub.path, timeout: 20)
        #expect(formatted == text)
    }

    /// A child that exits before reading its input leaves us writing into a
    /// closed pipe. `SIGPIPE`'s default disposition terminates the *process* —
    /// the whole app, killed by a formatter that rejected its arguments. If
    /// that regressed, this test does not fail, it takes the test binary down
    /// with it.
    @Test func aChildThatNeverReadsStdinDoesNotTakeTheProcessDown() throws {
        let stub = try makeStub("exit 0")
        let text = String(repeating: "const value = 1;\n", count: 20_000)
        #expect(try PrettierRunner.format(text, filePath: "/p/big.ts", binary: stub.path, timeout: 20) == nil)
    }

    @Test func aBinaryThatIsNotThereIsALaunchFailure() {
        do {
            _ = try PrettierRunner.format("x\n", filePath: "/p/main.ts", binary: "/nonexistent/prettier")
            #expect(Bool(false), "expected a failure")
        } catch let failure as PrettierFailure {
            #expect(failure.isLaunchFailure)
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    /// Prettier resolves plugins relative to where it runs, so the run has to
    /// happen in the project rather than wherever the app was launched from.
    @Test func theWorkingDirectoryIsHonoured() throws {
        let directory = try makeRoot()
        let stub = try makeStub("cat > /dev/null; printf '%s' \"$PWD\"")
        let formatted = try PrettierRunner.format(
            "x\n",
            filePath: "/p/main.ts",
            binary: stub.path,
            workingDirectory: directory.path
        )
        #expect(formatted?.hasSuffix(directory.lastPathComponent) == true)
    }

    // MARK: What reaches the reader

    /// The regression this section exists for: a save banner read
    /// *"Prettier couldn't format this file: The operation couldn't be
    /// completed. (Ghostty.PrettierFailure error 3.)"*, which is what
    /// `localizedDescription` answers for a bare Swift enum. It told the
    /// reader nothing, and it told whoever read the report less than
    /// nothing — 3 is the runtime's tag, and the runtime orders the payload
    /// cases first, so the number pointed at `failed` while the fault was
    /// `notFound`.
    @Test func everyFailureDescribesItselfRatherThanItsTag() {
        let failures: [PrettierFailure] = [
            .notFound,
            .launchFailed(reason: "No such file or directory"),
            .timedOut(seconds: 10),
            .failed(status: 2, message: "SyntaxError: Unexpected token (3:1)"),
        ]

        for failure in failures {
            #expect(failure.localizedDescription == failure.reason)
            #expect(!failure.localizedDescription.contains("PrettierFailure"))
        }
    }

    /// The one the reader actually hit: a project carrying a `.prettierrc`
    /// that never installed Prettier, on a machine that has none on `PATH`
    /// either. The banner has to say that, because it is the whole fix.
    @Test func aMissingPrettierSaysSoInWords() {
        #expect(
            PrettierFailure.notFound.localizedDescription
                == "prettier isn't installed in this project or on PATH."
        )
    }

    /// Prettier 3.9.6's real shape for a parse error, pasted from a run. The
    /// sentence is the first line; the rest is a code frame drawn in a
    /// monospaced column an alert does not have.
    @Test func aParseErrorsCodeFrameStaysOutOfTheBanner() {
        let stderr = """
            [error] /p/main.tsx: SyntaxError: Declaration or statement expected. (3:1)
            [error]   1 | const a = 1
            [error]   2 |
            [error] > 3 | }
            [error]     | ^
            [error]   4 |
            """

        #expect(
            PrettierFailure.failed(status: 2, message: stderr).reason
                == "/p/main.tsx: SyntaxError: Declaration or statement expected. (3:1)"
        )
    }

    /// A config naming a plugin that will not load, which is the case that
    /// prints a Node stack trace — twenty frames of Prettier's own bundle in
    /// the run this was taken from, enough to push the sentence out of an
    /// alert entirely.
    @Test func aPluginsStackTraceStaysOutOfTheBanner() {
        let stderr = """
            [error] /p/main.ts: Error: Cannot find package 'prettier-plugin-nope' imported from /p/noop.js
            [error]     at __node_internal_ (file:///p/node_modules/prettier/index.mjs:14106:11)
            [error]     at new NodeError (file:///p/node_modules/prettier/index.mjs:14071:5)
            [error]     at packageResolve (file:///p/node_modules/prettier/index.mjs:15012:9)
            """

        #expect(
            PrettierFailure.failed(status: 2, message: stderr).reason
                == "/p/main.ts: Error: Cannot find package 'prettier-plugin-nope' imported from /p/noop.js"
        )
    }

    /// Why the banner is not simply the first line. A malformed config takes
    /// three to say anything: on its own, `Invalid configuration for file`
    /// names no fault.
    @Test func aConfigurationErrorKeepsTheLinesThatNameTheFault() {
        let stderr = """
            [error] Invalid configuration for file "/p/main.ts":
            [error] YAML Error in /p/.prettierrc:
            [error] Flow map must end with a } at line 2, column 1:
            [error]\u{20}
            [error] { "semi": false
            [error]\u{20}
            [error] ^
            [error]\u{20}
            """

        #expect(
            PrettierFailure.failed(status: 2, message: stderr).reason == """
                Invalid configuration for file "/p/main.ts":
                YAML Error in /p/.prettierrc:
                Flow map must end with a } at line 2, column 1:
                { "semi": false
                """
        )
    }

    /// The bound on an unmeasured shape — a plugin free to print an essay.
    @Test func aBannerIsNotUnbounded() {
        let stderr = (1...40).map { "[error] line \($0)" }.joined(separator: "\n")
        let lines = PrettierFailure.failed(status: 2, message: stderr).reason
            .split(separator: "\n")

        #expect(lines.count == 4)
        #expect(lines.first == "line 1")
    }

    /// Trimming that removed everything would leave a banner saying nothing
    /// at all, which is the failure this whole section is about. A wall of
    /// text beats that.
    @Test func aMessageThatIsNothingButScaffoldingSurvivesWhole() {
        let stderr = "[error]   1 | const a = 1\n[error]     | ^\n"

        #expect(
            PrettierFailure.failed(status: 2, message: stderr).reason
                == "[error]   1 | const a = 1\n[error]     | ^"
        )
    }

    // MARK: Stubs

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-prettier-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An executable standing in for Prettier, so the behaviours that matter
    /// can be provoked deliberately instead of waited for.
    private func makeStub(_ body: String) throws -> URL {
        let url = try makeRoot().appendingPathComponent("prettier")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

private extension PrettierFailure {
    /// Pattern-matching one case without asserting the message, which is
    /// Foundation's wording and not ours.
    var isLaunchFailure: Bool {
        if case .launchFailed = self { return true }
        return false
    }
}
