import Foundation
@testable import Ghostty
import Testing

/// What happens to a path handed in from the Finder, a Dock drop or `open -a`.
///
/// The case that matters is the one that used to be wrong: a source file was
/// run as a shell script, so opening `config.ts` from the Finder executed its
/// contents against a login shell.
struct ExternalOpenIntentTests {
    @Test func aDirectoryOpensATerminalThere() {
        #expect(ExternalOpenIntent.decide(isDirectory: true, isExecutable: false) == .workingDirectory)
    }

    /// A directory with the executable bit — every directory has it, which is
    /// exactly why the directory question has to be asked first.
    @Test func aDirectoryIsADirectoryEvenThoughItIsExecutable() {
        #expect(ExternalOpenIntent.decide(isDirectory: true, isExecutable: true) == .workingDirectory)
    }

    /// The regression this exists for.
    @Test func anOrdinaryFileIsEditedRatherThanRun() {
        #expect(ExternalOpenIntent.decide(isDirectory: false, isExecutable: false) == .edit)
    }

    /// Someone who marked a file executable meant to run it, whatever it is
    /// called — so upstream's behaviour is kept exactly there.
    @Test func anExecutableFileStillRuns() {
        #expect(ExternalOpenIntent.decide(isDirectory: false, isExecutable: true) == .execute)
    }

    // MARK: Against real files

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ExternalOpenIntentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The bit is read from disk, not guessed from the name: a `.sh` someone
    /// is reading is edited, and the same content marked executable is run.
    @Test func theExecutableBitIsReadFromDiskRatherThanFromTheExtension() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let plain = root.appendingPathComponent("script.sh")
        try "echo hello\n".write(to: plain, atomically: true, encoding: .utf8)
        #expect(ExternalOpenIntent.decide(forPath: plain.path) == .edit)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plain.path)
        #expect(ExternalOpenIntent.decide(forPath: plain.path) == .execute)
    }

    @Test func aSourceFileIsEdited() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("config.ts")
        try "export const port = 3000\n".write(to: source, atomically: true, encoding: .utf8)
        #expect(ExternalOpenIntent.decide(forPath: source.path) == .edit)
    }

    @Test func aPathThatIsNotThereHasNoIntent() {
        #expect(ExternalOpenIntent.decide(forPath: "/nope/not/here") == nil)
    }
}
