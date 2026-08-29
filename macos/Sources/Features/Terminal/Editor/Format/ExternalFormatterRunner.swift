import Foundation

/// Everything a run of an external formatter can do other than produce
/// formatted text.
enum ExternalFormatterFailure: Error, Equatable, Sendable {
    /// The tool is not installed: not in the login shell's `PATH`, and not at
    /// the path the reader pointed the setting at.
    case notFound(tool: String, hint: String)

    case launchFailed(tool: String, reason: String)

    case timedOut(tool: String, seconds: TimeInterval)

    /// It ran and refused. `message` is what it said, which for these tools is
    /// nearly always a parse error with a line and column in it.
    case failed(tool: String, status: Int32, message: String)
}

extension ExternalFormatterFailure: LocalizedError {
    /// A sentence for a banner. Named tools, because "the formatter failed"
    /// leaves the reader guessing which of the several this editor can run
    /// they are being told about.
    var reason: String {
        switch self {
        case .notFound(let tool, let hint):
            return "\(tool) isn't installed. \(hint)"
        case .launchFailed(let tool, let reason):
            return "\(tool) didn't launch: \(reason)"
        case .timedOut(let tool, let seconds):
            return "\(tool) didn't answer within \(Int(seconds))s"
        case .failed(let tool, _, let message):
            return "\(tool): \(message)"
        }
    }

    var errorDescription: String? { reason }
}

/// Runs one external formatter over a buffer.
///
/// stdin rather than the file on disk, for the reason `PrettierRunner` gives:
/// the buffer is what the reader is looking at and it may never have been
/// saved in this state. The path still goes along as an argument, because it
/// is how these tools find their own configuration.
enum ExternalFormatterRunner {
    /// Shorter than Prettier's ten seconds. None of these is a Node program
    /// loading a plugin tree — they are single static binaries, and one that
    /// has not answered in five seconds is not about to.
    static let defaultTimeout: TimeInterval = 5

    /// The formatted text, or nil when nothing should change.
    ///
    /// Blocking; background tasks only.
    ///
    /// - Throws: `ExternalFormatterFailure`.
    static func format(
        _ text: String,
        filePath: String,
        formatter: ExternalFormatter,
        searchPath: String,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = defaultTimeout
    ) throws -> String? {
        guard let binary = locate(formatter.command, searchPath: searchPath) else {
            throw ExternalFormatterFailure.notFound(
                tool: formatter.displayName, hint: formatter.installHint)
        }

        let run = ShellCommand.runResult(
            binary,
            formatter.arguments(for: filePath),
            cwd: workingDirectory,
            environment: environment,
            stdin: Data(text.utf8),
            timeout: timeout
        )

        if let reason = run.launchFailure {
            throw ExternalFormatterFailure.launchFailed(
                tool: formatter.displayName, reason: reason)
        }

        return try result(
            status: run.status,
            stdout: run.stdout,
            stderr: run.stderr,
            tool: formatter.displayName,
            timeout: timeout)
    }

    /// An absolute path is taken as written — a reader who typed one is
    /// pointing at a binary the `PATH` may not hold. Everything else is looked
    /// up the way the language servers are.
    static func locate(_ command: String, searchPath: String) -> String? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        return LSPProcess.locate(command, searchPath: searchPath)
    }

    /// Reads a finished run, with `status == nil` meaning it was killed at the
    /// deadline.
    ///
    /// **The order is the whole of it, and it is the same order and the same
    /// reason as `PrettierRunner.result`:** the status is checked first, and
    /// only then whether anything came back. A formatter handed a file with a
    /// syntax error in it — which is what a buffer is halfway through a
    /// function — exits non-zero and prints nothing on stdout. An
    /// implementation that read stdout first would answer "the file is now
    /// empty" every time somebody saved mid-edit.
    ///
    /// Empty output on a *successful* exit is then still read as no change
    /// rather than as an empty file. Declining to blank somebody's buffer is
    /// the safe direction to be wrong in.
    static func result(
        status: Int32?,
        stdout: String,
        stderr: String,
        tool: String,
        timeout: TimeInterval = defaultTimeout
    ) throws -> String? {
        guard let status else {
            throw ExternalFormatterFailure.timedOut(tool: tool, seconds: timeout)
        }

        guard status == 0 else {
            throw ExternalFormatterFailure.failed(
                tool: tool,
                status: status,
                message: message(stdout: stdout, stderr: stderr, tool: tool))
        }

        return stdout.isEmpty ? nil : stdout
    }

    /// stderr first: that is where the parse error with the line number is.
    /// stdout is the fallback for the tools that print their complaint there.
    private static func message(stdout: String, stderr: String, tool: String) -> String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        return "\(tool) failed without saying why."
    }
}
