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

extension PrettierFailure {
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
            return message
        }
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
    /// - Throws: `PrettierFailure`.
    static func format(
        _ text: String,
        filePath: String,
        binary: String,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = defaultTimeout
    ) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--stdin-filepath", filePath]
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
        if let environment { process.environment = environment }

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw PrettierFailure.launchFailed(reason: error.localizedDescription)
        }

        /// All three pipes are worked concurrently, and none of them may be
        /// left until another is finished. A buffer larger than a pipe (~64KB
        /// on this platform) blocks the writer until somebody reads, and the
        /// formatted copy coming back is about the same size — so writing the
        /// whole of stdin before reading stdout deadlocks on any file worth
        /// formatting, with both processes waiting on the other.
        DispatchQueue.global(qos: .userInitiated).async {
            send(Data(text.utf8), to: input.fileHandleForWriting)
        }

        let collected = Collected()
        let group = DispatchGroup()
        for (pipe, isError) in [(output, false), (errors, true)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.store(data, isError: isError)
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            kill(process)
        }

        /// The process has exited, so both read ends are at EOF and the
        /// drains are about to finish; the bound only guards a stuck reader.
        _ = group.wait(timeout: .now() + 2)

        return try result(
            status: timedOut ? nil : process.terminationStatus,
            stdout: collected.text(isError: false),
            stderr: collected.text(isError: true),
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

    // MARK: Private

    /// Both output streams, written from two queues and read from a third.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()

        func store(_ data: Data, isError: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isError { err = data } else { out = data }
        }

        func text(isError: Bool) -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: isError ? err : out, encoding: .utf8) ?? ""
        }
    }

    /// Writes the whole buffer to the child and closes the pipe, which is what
    /// tells Prettier the input has ended — without it, Prettier waits and we
    /// time out.
    ///
    /// Written through the descriptor rather than `FileHandle.write(_:)`
    /// because of what happens when the child is already gone: Prettier
    /// rejecting its arguments exits before reading a byte, and writing into
    /// that pipe raises `SIGPIPE`, whose default disposition terminates the
    /// process — the whole app, killed by a mistyped flag. `F_SETNOSIGPIPE`
    /// turns that into an `EPIPE` return this loop can simply stop on.
    private static func send(_ data: Data, to handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        defer { try? handle.close() }

        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if written == 0 { return }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    /// Ends a run that outlived its deadline, and makes sure it ended.
    ///
    /// `terminate()` is `SIGTERM`, which a Node process under a shell wrapper
    /// is free to ignore — and `node_modules/.bin/prettier` is a wrapper.
    /// `SIGKILL` cannot be caught.
    private static func kill(_ process: Process) {
        process.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            Foundation.kill(process.processIdentifier, SIGKILL)
        }
    }
}
