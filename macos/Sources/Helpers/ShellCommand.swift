import Foundation

/// Runs short-lived commands that enrich sidebar metadata (`git`, `gh`,
/// `ps`, `lsof`).
enum ShellCommand {
    /// How long to wait for the pipe readers once the child has exited.
    ///
    /// By then both write ends are closed, so a reader that gets a core
    /// returns immediately and this costs nothing. What can be slow is the
    /// *scheduling*: the readers run at utility quality of service, and a
    /// machine with few cores, several subprocesses in flight and a caller
    /// spinning on the main thread can leave them waiting seconds for one.
    ///
    /// This was two seconds, and a reader that missed it lost its output
    /// while the exit status still said the command had succeeded — a
    /// `git worktree list` that printed four hundred bytes arriving as a
    /// repository with no worktrees. Long enough that only a genuinely
    /// stuck reader reaches it, and a reader that does is now reported as
    /// a failure rather than as a command that said nothing.
    private static let drainGrace: TimeInterval = 15

    /// Collects stdout off the polling thread. Draining has to happen
    /// concurrently with the wait: a command whose output overflows the
    /// pipe buffer blocks writing until someone reads, so waiting first
    /// would hang, and reading first would ignore the timeout.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        var data: Data {
            lock.withLock { storage }
        }

        func store(_ data: Data) {
            lock.withLock { storage = data }
        }

        func append(_ data: Data) {
            lock.withLock { storage.append(data) }
        }
    }

    /// Buffers incoming chunks and emits whole lines to `onLine`, appending
    /// the raw data to `sink` for the final `Result`.
    private final class LineSplitter: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private let sink: Output
        private let onLine: (String) -> Void

        init(sink: Output, onLine: @escaping (String) -> Void) {
            self.sink = sink
            self.onLine = onLine
        }

        /// The remainder is kept exactly as it arrived, `\r` included: a
        /// chunk can end between the `\r` and the `\n` of one terminator,
        /// and trimming the buffer would lose the half that has to pair
        /// with the next chunk.
        func ingest(_ data: Data) {
            sink.append(data)
            lock.withLock {
                pending += String(data: data, encoding: .utf8) ?? ""
                var lines = pending.splitIntoLines()
                if let last = lines.popLast() {
                    pending = last
                }
                for line in lines {
                    onLine(line.droppingTrailingCarriageReturn)
                }
            }
        }

        func flush() {
            lock.withLock {
                guard !pending.isEmpty else { return }
                onLine(pending.droppingTrailingCarriageReturn)
                pending = ""
            }
        }
    }

    /// Starts writing `data` to the child's stdin from another queue.
    ///
    /// Concurrent with the drain, and not optionally so: a buffer larger than
    /// a pipe (~64KB on this platform) blocks the writer until somebody
    /// reads, and what a filter hands back is about the same size — so
    /// writing the whole of stdin before reading stdout deadlocks on any
    /// input worth piping, with both processes waiting on the other.
    private static func feed(_ data: Data, into pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async {
            send(data, to: pipe.fileHandleForWriting)
        }
    }

    /// Writes the whole buffer to the child and closes the pipe, which is what
    /// tells it the input has ended — without the close, a filter reading to
    /// EOF waits and we time out.
    ///
    /// Written through the descriptor rather than `FileHandle.write(_:)`
    /// because of what happens when the child is already gone: a command that
    /// rejects its arguments exits before reading a byte, and writing into
    /// that pipe raises `SIGPIPE`, whose default disposition terminates the
    /// *writer* — the whole app, killed by a mistyped flag. `F_SETNOSIGPIPE`
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

    /// Ends a process that outlived its timeout, and makes sure it ended.
    ///
    /// `terminate()` is SIGTERM, which a process is free to ignore — and a
    /// login shell sourcing someone's rc files does exactly that often
    /// enough to matter. Observed after a burst of PATH probes: several
    /// `zsh -lic` still resident minutes later, one per abandoned call.
    /// SIGKILL cannot be caught, so it is what actually closes the door.
    private static func kill(_ process: Process) {
        process.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            Foundation.kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Returns the command's stdout, or nil when it can't be launched,
    /// exits non-zero, or outlives `timeout`.
    ///
    /// This blocks the calling thread while it waits, so it belongs on a
    /// background task — never the main actor.
    static func run(
        _ launchPath: String,
        _ arguments: [String],
        cwd: String? = nil,
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let output = Output()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.store(stdout.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            Self.kill(process)
            return nil
        }

        // The process has exited, so the read side is at EOF and the drain
        // is about to finish; the bound only guards against a stuck reader.
        guard drained.wait(timeout: .now() + 2) == .success,
              process.terminationStatus == 0
        else { return nil }

        return String(data: output.data, encoding: .utf8)
    }

    /// What a command actually did.
    struct Result {
        /// The process exit status, or nil when it never ran to completion
        /// (failed to launch, or was killed at the timeout).
        var status: Int32?
        var stdout: String
        var stderr: String

        /// Why the command could not be started at all, when that is what
        /// happened.
        ///
        /// A launch failure and a kill at the deadline both leave `status`
        /// nil, and they are not the same news: one is a binary that isn't
        /// there, the other is a binary that never answered. A caller that
        /// reports them differently — `PrettierRunner`, whose failure type
        /// has a case for each — has nothing else to tell them apart by.
        var launchFailure: String?

        var succeeded: Bool { status == 0 }

        /// The best line to put in front of a user. Git says useful things
        /// on both streams depending on the subcommand.
        var message: String {
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !err.isEmpty { return err }
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { return out }
            return status == nil ? "The command timed out." : "The command failed."
        }
    }

    /// Runs a command and reports everything about how it went.
    ///
    /// `run` above answers "what did this print", which is all a status
    /// query needs. Anything that *changes* something needs more than that,
    /// and `run` structurally can't give it: it discards the exit status,
    /// never drains stderr, and collapses launch failure, timeout and
    /// non-zero exit into the same `nil`. Git in particular communicates
    /// through all three — `diff --quiet` answers only in the exit code,
    /// and a failed `push` explains itself only on stderr.
    ///
    /// Both pipes are drained concurrently. Draining only stdout is a
    /// deadlock waiting to happen: a command that writes more than a pipe
    /// buffer (~64KB) to stderr blocks forever, and git is chatty there.
    ///
    /// A `stdin` is written from a third queue while those two drain — see
    /// `feed(_:into:)` for why that cannot be done first — and closed, which
    /// is what tells a filter its input has ended. This is how a command gets
    /// a buffer that was never saved to disk: `prettier --stdin-filepath`.
    ///
    /// Blocks the calling thread — background tasks only, never the main
    /// actor.
    static func runResult(
        _ launchPath: String,
        _ arguments: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe = stdin.map { _ in Pipe() }
        if let inPipe {
            process.standardInput = inPipe
        } else {
            // Nothing sensible can be read from a GUI app's stdin, and a child
            // that blocks reading it would hang until the timeout.
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            return Result(
                status: nil,
                stdout: "",
                stderr: error.localizedDescription,
                launchFailure: error.localizedDescription
            )
        }

        if let stdin, let inPipe { feed(stdin, into: inPipe) }

        let outData = Output()
        let errData = Output()
        let group = DispatchGroup()

        for (pipe, sink) in [(outPipe, outData), (errPipe, errData)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                sink.store(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            Self.kill(process)
        }

        let drained = group.wait(timeout: .now() + Self.drainGrace) == .success

        return Result(
            status: timedOut || !drained ? nil : process.terminationStatus,
            stdout: String(data: outData.data, encoding: .utf8) ?? "",
            stderr: String(data: errData.data, encoding: .utf8) ?? ""
        )
    }

    /// Like `runResult`, but forwards output to `onOutput` as it arrives,
    /// line by line, while still returning the full `Result` when done.
    ///
    /// The callback runs on a background dispatch queue — hop to the main
    /// actor inside it before touching any UI. Blocks the calling thread;
    /// background tasks only.
    static func runStreaming(
        _ launchPath: String,
        _ arguments: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        onOutput: @escaping (String) -> Void
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return Result(
                status: nil,
                stdout: "",
                stderr: error.localizedDescription,
                launchFailure: error.localizedDescription
            )
        }

        let outData = Output()
        let errData = Output()
        let outLines = LineSplitter(sink: outData, onLine: onOutput)
        let errLines = LineSplitter(sink: errData, onLine: onOutput)
        let group = DispatchGroup()

        for (pipe, splitter) in [(outPipe, outLines), (errPipe, errLines)] {
            group.enter()
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    splitter.flush()
                    group.leave()
                } else {
                    splitter.ingest(data)
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            Self.kill(process)
        }

        // The pipes drain asynchronously; give the readers a moment to hit
        // EOF before assembling the result.
        _ = group.wait(timeout: .now() + 2)

        return Result(
            status: timedOut ? nil : process.terminationStatus,
            stdout: String(data: outData.data, encoding: .utf8) ?? "",
            stderr: String(data: errData.data, encoding: .utf8) ?? ""
        )
    }
}
