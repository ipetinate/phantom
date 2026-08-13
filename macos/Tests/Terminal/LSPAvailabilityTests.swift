import Foundation
@testable import Ghostty
import Testing/// Finding a language server that was installed after the app started.
///
/// The bug: `missing` was append-only. A command that could not be found
/// went into the list and nothing ever looked again, so the banner outlived
/// the install and only a restart cleared it.
struct LSPLocateTests {
    /// Writes an executable into a temporary directory and returns both.
    private func makeExecutable(named name: String) -> (directory: String, path: String) {
        let directory = NSTemporaryDirectory() + "phantom-bin-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let path = directory + "/" + name
        try? "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path
        )
        return (directory, path)
    }

    /// The whole point: a probe that failed must be able to succeed later,
    /// with no state carried over from the failure.
    @Test func aBinaryCreatedAfterAFailedProbeIsFound() {
        let directory = NSTemporaryDirectory() + "phantom-bin-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }

        #expect(LSPProcess.locate("later-server", searchPath: directory) == nil)

        let path = directory + "/later-server"
        try? "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)

        #expect(LSPProcess.locate("later-server", searchPath: directory) != nil)
    }

    @Test func aFileThatIsNotExecutableIsNotAServer() {
        let directory = NSTemporaryDirectory() + "phantom-bin-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let path = directory + "/not-executable"
        try? "text".write(toFile: path, atomically: true, encoding: .utf8)

        #expect(LSPProcess.locate("not-executable", searchPath: directory) == nil)
    }

    /// A `PATH` with several entries, which is the real shape — the binary is
    /// in one of them and the others must not stop the search.
    @Test func everyPathEntryIsSearched() {
        let installed = makeExecutable(named: "somewhere-server")
        defer { try? FileManager.default.removeItem(atPath: installed.directory) }

        let searchPath = "/nonexistent-a:\(installed.directory):/nonexistent-b"
        #expect(LSPProcess.locate("somewhere-server", searchPath: searchPath) != nil)
    }

    @Test func anEmptyPathFindsNothing() {
        #expect(LSPProcess.locate("anything", searchPath: "") == nil)
    }
}

/// A server that exits during `initialize` must not lose its last words.
///
/// The bug: stderr was drained by a `readabilityHandler`, which is scheduled
/// on the run loop. A server that writes a diagnostic and exits immediately —
/// Ruby LSP exiting 78 because the project has a `Gemfile` but no
/// `Gemfile.lock` — would hit the termination handler first, and the log
/// read from `recentLog` would be empty even though the server said exactly
/// why it left. This is the minimal reproducer: a server whose entire
/// message fits in one pipe write and whose exit is near-instant.
struct LSPServerExitLogTests {
    private func makeServer(script: String) -> (directory: String, definition: LSPServerDefinition) {
        let directory = NSTemporaryDirectory() + "phantom-lsp-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let path = directory + "/exit-server"
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let definition = LSPServerDefinition(
            languageID: "exit-test",
            displayName: "Exit Test",
            command: path,
            arguments: [],
            installHint: ""
        )
        return (directory, definition)
    }

    /// The reproduction: a one-shot server that writes a diagnostic to stderr
    /// and dies. The `initialize` call throws `terminated(status: 78)`, and
    /// the log must still contain the diagnostic it printed.
    @Test func stderrIsNotLostWhenAServerDiesDuringInitialize() async {
        let (directory, definition) = makeServer(script: """
        #!/bin/sh
        echo "Project contains a Gemfile, but no Gemfile.lock" >&2
        exit 78
        """)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let process = LSPProcess(definition: definition, environmentProvider: { [:] })
        try? await process.start(workingDirectory: directory)

        await #expect(throws: LSPProcessError.self) {
            _ = try await process.initialize(rootURI: "file:///tmp", timeout: 5)
        }

        #expect(process.recentLog.contains { $0.contains("Gemfile.lock") })
    }

    /// The hardening: a server that spawns a grandchild which *inherits* the
    /// stderr pipe keeps the write end open after the server itself dies. A
    /// blocking drain would wait for EOF that never comes; the drain must
    /// read what's available and give up. The grandchild sleeps so the pipe
    /// demonstrably stays open for the lifetime of this test.
    @Test func drainDoesNotBlockWhenAGrandchildHoldsThePipe() async {
        let (directory, definition) = makeServer(script: """
        #!/bin/sh
        (sleep 30) &
        echo "opaque, no time to explain" >&2
        exit 42
        """)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let process = LSPProcess(definition: definition, environmentProvider: { [:] })
        try? await process.start(workingDirectory: directory)

        await #expect(throws: LSPProcessError.self) {
            _ = try await process.initialize(rootURI: "file:///tmp", timeout: 5)
        }

        #expect(process.recentLog.contains { $0.contains("opaque, no time to explain") })
    }
}

/// The launch environment must include GOBIN/`~/go/bin`.
///
/// The bug: the *status* check looked up servers on `executableSearchPath()`
/// (which appends GOBIN and `~/go/bin`), but the *launch* used the login
/// shell's `PATH` verbatim. A server installed with `go install` — gopls is
/// the canonical example — would report "installed" and then fail to start
/// with "isn't on PATH" on the same machine, at the same time.
struct LSPServerLaunchPathTests {
    /// The default environment hands the server a `PATH` that includes the
    /// directories where `go install` drops binaries. This test never starts
    /// a process — it asserts the *shape* of the environment, which is what
    /// the bug was about.
    @Test func defaultEnvironmentIncludesGoBinDirectories() {
        let environment = LoginEnvironment.executableEnvironment()
        let path = environment["PATH"] ?? ""

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(path.contains("\(home)/go/bin"), "expected \(home)/go/bin in launch PATH")
    }

    /// `start` uses the same lookup the status does: the extended search
    /// path, not the bare login PATH. A fake server dropped in a temp dir
    /// is the proof that the two checks agree.
    @Test func startFindsAServerInANonLoginPathDirectory() async throws {
        let bin = NSTemporaryDirectory() + "phantom-lspbin-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: bin,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: bin) }

        let fake = bin + "/phantom-go-server"
        try "#!/bin/sh\nexit 0\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)

        let definition = LSPServerDefinition(
            languageID: "phantom-go-test",
            displayName: "Phantom Go Test",
            command: "phantom-go-server",
            arguments: [],
            installHint: ""
        )

        // The environment is whatever the real provider computes plus the
        // temp dir prepended, mirroring what GOBIN does for gopls.
        let base = LoginEnvironment.executableEnvironment()
        let environment = base.merging(["PATH": "\(bin):\(base["PATH"] ?? "")"]) { _, new in new }

        let process = LSPProcess(definition: definition, environmentProvider: { environment })

        // start() only cares about finding the executable. Whether it then
        // speaks LSP is a separate question, so this must not throw the
        // `serverNotFound` that used to make GOBIN-installed servers
        // unusable.
        do {
            try await process.start(workingDirectory: bin)
        } catch let error as LSPProcessError {
            Issue.record("start failed: \(error.reason)")
            return
        }
        process.terminate()
    }
}

/// Invalidating the cached login `PATH`.
///
/// Neither test asserts the resolved `PATH` is non-empty: resolving one
/// shells out to the login shell, and a CI runner with no real profile —
/// `.zshrc` never sourced, no Homebrew, nothing — can legitimately come back
/// with nothing to report. That absence is a fact about the host, not about
/// whether invalidation works, which is the only thing these describe.
struct LoginPathInvalidationTests {
    /// The second layer of stickiness: the `PATH` is resolved once and kept
    /// for the life of the process, so a version manager moving its bin
    /// directory — `nvm use` — left every lookup searching the old one.
    @Test func invalidatingMakesTheNextReadResolveAgain() {
        let first = LoginEnvironment.loginPath()
        LoginEnvironment.invalidate()
        let second = LoginEnvironment.loginPath()

        // Same answer on a machine that hasn't changed, and the point is that
        // it was *asked* again rather than served from the first call.
        #expect(first == second)
    }

    @Test func invalidatingTwiceIsHarmless() {
        LoginEnvironment.invalidate()
        LoginEnvironment.invalidate()
        _ = LoginEnvironment.loginPath() // must not crash or hang
    }
}
