import Foundation

/// Runs short-lived commands that enrich sidebar metadata (`git`, `gh`,
/// `ps`, `lsof`).
enum ShellCommand {
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
    /// Blocks the calling thread — background tasks only, never the main
    /// actor.
    static func runResult(
        _ launchPath: String,
        _ arguments: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
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

        // Nothing sensible can be read from a GUI app's stdin, and a child
        // that blocks reading it would hang until the timeout.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(status: nil, stdout: "", stderr: error.localizedDescription)
        }

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

        _ = group.wait(timeout: .now() + 2)

        return Result(
            status: timedOut ? nil : process.terminationStatus,
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
            return Result(status: nil, stdout: "", stderr: error.localizedDescription)
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
