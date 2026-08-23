import Foundation

/// Everything a run of Prettier can do other than produce formatted text.
enum PrettierFailure: Error, Equatable, Sendable {
    /// Nothing to run: no Prettier in the project, none on the login shell's
    /// `PATH`.
    case notFound

    /// The binary could not be started at all.
    case launchFailed(reason: String)

    /// Killed at the deadline. Nothing usable came back.
    case timedOut(seconds: TimeInterval)

    /// Prettier ran and refused. `message` is what it said, which is nearly
    /// always a parse error with a line and column in it.
    case failed(status: Int32, message: String)
}

extension PrettierFailure: LocalizedError {
    /// A sentence for a banner, not a value anything parses back apart.
    var reason: String {
        switch self {
        case .notFound:
            return "prettier isn't installed in this project or on PATH."
        case .launchFailed(let reason):
            return "prettier didn't launch: \(reason)"
        case .timedOut(let seconds):
            return "prettier didn't answer within \(Int(seconds))s"
        case .failed(_, let message):
            return Self.banner(from: message)
        }
    }

    /// The conformance exists for one reason: `localizedDescription`.
    ///
    /// A Swift enum that is only an `Error` bridges to an `NSError` whose
    /// description is *"The operation couldn't be completed.
    /// (Ghostty.PrettierFailure error 3.)"* — and 3 is not even the third
    /// case, it is the runtime's tag, which puts the payload cases first.
    /// Any presenter reaching for `localizedDescription`, which is the
    /// obvious thing to reach for, therefore replaces Prettier's diagnosis
    /// with a number that decodes to nothing. Answering it here means no
    /// call site has to know that, rather than each one remembering to ask
    /// for `reason` instead.
    var errorDescription: String? { reason }
}

private extension PrettierFailure {
    /// An alert can hold a diagnosis. It cannot hold a terminal.
    ///
    /// Measured against Prettier 3.9.6 rather than assumed. Every line it
    /// writes to stderr carries an `[error] ` marker, and around the sentence
    /// that says what is actually wrong it prints two kinds of padding: the
    /// code frame under a parse error, and — when a config asks for a plugin
    /// that will not load — a Node stack trace, twenty frames of Prettier's
    /// own bundle. Both are shaped by a monospaced column that an alert does
    /// not have, and the trace is long enough to push the sentence out of
    /// sight entirely.
    ///
    /// What survives is kept whole rather than cut to the first line, because
    /// a bad config announces itself across three: `Invalid configuration for
    /// file "…":` on its own names no fault. The cap is there for the case
    /// nobody has measured yet — a plugin free to print an essay — and it is
    /// deliberately loose enough never to reach the four cases above.
    static var maximumBannerLines: Int { 4 }

    static func banner(from message: String) -> String {
        let kept = message
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(Self.withoutErrorMarker)
            .filter { !$0.allSatisfy(\.isWhitespace) && !Self.isFrame($0) }
            .prefix(maximumBannerLines)

        /// Nothing left means the shape was one this has never seen, and a
        /// wall of text beats an empty banner.
        return kept.isEmpty
            ? message.trimmingCharacters(in: .whitespacesAndNewlines)
            : kept.joined(separator: "\n")
    }

    /// Prettier's own `[error] ` prefix, which it puts on continuation and
    /// blank lines too.
    static func withoutErrorMarker(_ line: Substring) -> Substring {
        guard line.hasPrefix("[error]") else { return line }
        let rest = line.dropFirst("[error]".count)
        return rest.hasPrefix(" ") ? rest.dropFirst() : rest
    }

    /// A line that is scaffolding rather than sentence: a code frame's
    /// gutter (`  1 | const a = 1`, `> 3 | }`, `    | ^`) or a JavaScript
    /// stack frame.
    static func isFrame(_ line: Substring) -> Bool {
        let indented = line.first == " " || line.first == "\t"
        var rest = line.drop { $0 == " " || $0 == "\t" }
        if indented, rest.hasPrefix("at ") { return true }

        if rest.hasPrefix(">") { rest = rest.dropFirst().drop { $0 == " " } }
        if rest.hasPrefix("|") { return true }

        let gutter = rest.prefix(while: \.isNumber)
        guard !gutter.isEmpty else { return false }
        return rest.dropFirst(gutter.count).drop { $0 == " " }.hasPrefix("|")
    }
}

/// Runs `prettier --stdin-filepath <path>` over a buffer.
///
/// stdin rather than the file on disk, because the buffer is what the reader
/// is looking at and it may never have been saved in this state. The path
/// still goes along: `--stdin-filepath` is how Prettier is told which parser
/// to use and, more importantly, where to resolve its own configuration and
/// `.prettierignore` from — see `PrettierProject` for why that resolution is
/// left entirely to Prettier.
enum PrettierRunner {
    /// Generous, because the first run in a monorepo pays for Node's startup
    /// and for loading every plugin the config asks for. Bounded, because
    /// this sits between ⌘S and the file being written.
    static let defaultTimeout: TimeInterval = 10

    /// The formatted text, or **nil when nothing should change**.
    ///
    /// The process mechanics belong to `ShellCommand`: the concurrent drain
    /// of all three pipes, the deadline and the `SIGKILL` behind it, and the
    /// `SIGPIPE`-safe write of the buffer into a child that may already have
    /// exited. What is Prettier's own, and stays here, is the reading of what
    /// came back — see `result(status:stdout:stderr:timeout:)`.
    ///
    /// - Throws: `PrettierFailure`.
    static func format(
        _ text: String,
        filePath: String,
        binary: String,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = defaultTimeout
    ) throws -> String? {
        let run = ShellCommand.runResult(
            binary,
            ["--stdin-filepath", filePath],
            cwd: workingDirectory,
            environment: environment,
            stdin: Data(text.utf8),
            timeout: timeout
        )

        if let reason = run.launchFailure {
            throw PrettierFailure.launchFailed(reason: reason)
        }

        return try result(
            status: run.status,
            stdout: run.stdout,
            stderr: run.stderr,
            timeout: timeout
        )
    }

    /// Reads a finished run, with `status == nil` meaning it was killed at the
    /// deadline.
    ///
    /// Pure, and separate from the running, because the rule below is the one
    /// piece of this file that can destroy somebody's work and it has to be
    /// testable without a Prettier on the machine.
    ///
    /// ## Empty output is *never* read as an empty file
    ///
    /// Measured against Prettier 2.8.8 and 3.9.6 rather than assumed, because
    /// the folklore here is wrong in a way that matters. A file covered by
    /// `.prettierignore` — or by one of Prettier's own default ignores, such as
    /// `node_modules` — does **not** produce empty output: both versions echo
    /// the input back verbatim and exit 0. That case is therefore safe by
    /// construction, and arrives here as "identical text", which `PrettierEdit`
    /// turns into no edit.
    ///
    /// What *does* produce empty output on exit 0 is a file of nothing but
    /// whitespace, where empty is Prettier's genuine answer. And what produces
    /// empty output on exit **2** is every real failure: a parse error, and a
    /// file Prettier has no parser for. Both print nothing at all on stdout.
    ///
    /// So the rule that matters is the *order*: the status is checked first, and
    /// only then the emptiness. An implementation that looked at stdout first
    /// would replace the buffer with nothing every time the reader saved a file
    /// with a syntax error in it — which is to say, every time they saved
    /// halfway through writing a function.
    ///
    /// Empty output is then still reported as no-change rather than as an empty
    /// result, as a backstop that costs one real transformation: a
    /// whitespace-only file will not be emptied here. Declining to blank
    /// somebody's buffer is the safe direction to be wrong in, and a file of
    /// blank lines staying a file of blank lines is a change nobody will miss.
    ///
    static func result(
        status: Int32?,
        stdout: String,
        stderr: String,
        timeout: TimeInterval = defaultTimeout
    ) throws -> String? {
        guard let status else { throw PrettierFailure.timedOut(seconds: timeout) }

        guard status == 0 else {
            throw PrettierFailure.failed(status: status, message: message(stdout: stdout, stderr: stderr))
        }

        return stdout.isEmpty ? nil : stdout
    }

    /// What to put in front of the user when Prettier refuses.
    ///
    /// stderr first: that is where the parse error with the line number is,
    /// and swallowing it turns "formatting didn't work" into a question
    /// nobody can answer. stdout is the fallback only because a broken shim
    /// in `node_modules/.bin` can put its complaint there instead.
    private static func message(stdout: String, stderr: String) -> String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        return "prettier failed without saying why."
    }
}
