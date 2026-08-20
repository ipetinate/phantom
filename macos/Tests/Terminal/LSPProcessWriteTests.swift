import Foundation
@testable import Ghostty
import Testing

/// Writing to a language server that has stopped reading.
///
/// This is the shape of a reported freeze: `zls` was installed, a Zig file was
/// opened, and the whole window locked up until the app was force-quit. A
/// server resolving a `build.zig` graph does not drain its stdin while it
/// works, a pipe holds about 64KB, and full-document sync sends the entire file
/// on every keystroke — so the buffer fills in a few edits. The write was
/// dispatched with `sync` from `LSPCenter`, which is `@MainActor`; the main
/// thread then waited on a pipe an external process had stopped reading.
///
/// The server here is `/bin/sleep`, chosen because it is the simplest process
/// that never reads its stdin — exactly the condition that hangs.
struct LSPProcessWriteTests {
    private var sleeper: LSPServerDefinition {
        LSPServerDefinition(
            languageID: "writetest",
            displayName: "Sleeper",
            command: "/bin/sleep",
            arguments: ["30"],
            installHint: ""
        )
    }

    /// Half a megabyte, eight times the pipe's capacity, so the buffer is
    /// certainly full well before the last write. With a synchronous write this
    /// blocks until `sleep` exits half a minute later.
    @Test func writingPastThePipeBufferDoesNotBlockTheCaller() async throws {
        let process = LSPProcess(definition: sleeper)
        try await process.start(workingDirectory: NSTemporaryDirectory())
        defer { process.terminate() }

        let line = String(repeating: "x", count: 8192)
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            for _ in 0..<64 {
                try? process.notify("textDocument/didChange", params: ["text": .string(line)])
            }
        }

        #expect(elapsed < .seconds(2), "64 writes of 8KB took \(elapsed)")
    }

    /// And it still refuses once the process is gone, which is the one error
    /// the caller can act on — the write itself no longer reports anything.
    @Test func writingToADeadProcessThrows() async throws {
        let process = LSPProcess(definition: sleeper)
        try await process.start(workingDirectory: NSTemporaryDirectory())
        process.terminate()

        /// Termination is observed through the process's own handler, so give
        /// it a moment to be seen rather than racing it.
        try await Task.sleep(for: .milliseconds(300))

        #expect(throws: (any Error).self) {
            try process.notify("textDocument/didChange", params: ["text": "x"])
        }
    }
}
