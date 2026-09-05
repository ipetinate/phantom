import Foundation
@testable import Ghostty
import Testing

struct ExtensionInstallerStagingTests {
    private struct Fixture {
        let scratch: URL
        let archive: URL
        let entry: ExtensionIndex.Entry

        func staged(_ name: String = "staged") -> URL {
            scratch.appendingPathComponent(name, isDirectory: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    private func manifest(id: String, version: String) -> String {
        """
        {
          "schemaVersion": 1,
          "id": "\(id)",
          "name": "Lua",
          "version": "\(version)",
          "publisher": "tests",
          "contributes": { "languages": [{ "languageId": "lua", "extensions": ["lua"] }] }
        }
        """
    }

    private func makeFixture(
        id: String = "tests.lua",
        version: String = "1.0.0",
        manifestVersion: String? = nil,
        symlink: Bool = false
    ) throws -> Fixture {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("phantom-staging-\(UUID().uuidString)", isDirectory: true)
        let source = scratch.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(
            at: source.appendingPathComponent("media", isDirectory: true), withIntermediateDirectories: true)
        try manifest(id: id, version: manifestVersion ?? version).write(
            to: source.appendingPathComponent(LanguageManifest.fileName), atomically: true, encoding: .utf8)
        try "# Lua\n".write(
            to: source.appendingPathComponent(ExtensionCard.documentFileName), atomically: true, encoding: .utf8)
        try Data(count: 16).write(to: source.appendingPathComponent("media/a.png"))
        if symlink {
            try fileManager.createSymbolicLink(
                atPath: source.appendingPathComponent("link.json").path, withDestinationPath: LanguageManifest.fileName)
        }

        let archive = scratch.appendingPathComponent("\(id)-\(version).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--norsrc", source.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        try #require(ditto.terminationStatus == 0)

        let bytes = try #require(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let entry = ExtensionIndex.Entry(
            id: id,
            name: "Lua",
            version: version,
            publisher: "tests",
            summary: "",
            homepage: nil,
            minimumPhantomVersion: nil,
            contributes: ["languages"],
            languages: ["lua"],
            downloadURL: URL(string: "https://example.com/\(id).zip")!,
            sha256: try ExtensionInstaller.digest(of: archive),
            bytes: bytes)
        return Fixture(scratch: scratch, archive: archive, entry: entry)
    }

    private func with(_ entry: ExtensionIndex.Entry, sha256: String? = nil, bytes: Int? = nil) -> ExtensionIndex.Entry {
        ExtensionIndex.Entry(
            id: entry.id,
            name: entry.name,
            version: entry.version,
            publisher: entry.publisher,
            summary: entry.summary,
            homepage: entry.homepage,
            minimumPhantomVersion: entry.minimumPhantomVersion,
            contributes: entry.contributes,
            languages: entry.languages,
            downloadURL: entry.downloadURL,
            sha256: sha256 ?? entry.sha256,
            bytes: bytes ?? entry.bytes)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test func stagesAnArchiveTheRegistryVouchesFor() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let staged = fixture.staged()

        try await ExtensionInstaller.stage(archive: fixture.archive, expecting: fixture.entry, into: staged)

        #expect(exists(staged.appendingPathComponent(LanguageManifest.fileName)))
        #expect(exists(staged.appendingPathComponent(ExtensionCard.documentFileName)))
        #expect(exists(staged.appendingPathComponent("media/a.png")))
        let manifest = try #require(LanguageManifest.load(directory: staged, scope: .user))
        #expect(manifest.id == "tests.lua")
        #expect(manifest.version == "1.0.0")
        try ExtensionInstaller.inspect(staged)
    }

    @Test func refusesAnArchiveWhoseDigestDiffers() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let wrong = with(fixture.entry, sha256: String(repeating: "0", count: 64))

        await #expect(throws: ExtensionInstaller.Failure.digestMismatch) {
            try await ExtensionInstaller.stage(archive: fixture.archive, expecting: wrong, into: fixture.staged())
        }
        #expect(!exists(fixture.staged()))
    }

    @Test func refusesAnArchiveWhoseSizeDiffers() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let wrong = with(fixture.entry, bytes: fixture.entry.bytes + 1)

        await #expect(throws: ExtensionInstaller.Failure.sizeMismatch(
            received: fixture.entry.bytes, expected: fixture.entry.bytes + 1)
        ) {
            try await ExtensionInstaller.stage(archive: fixture.archive, expecting: wrong, into: fixture.staged())
        }
    }

    @Test func refusesASymbolicLinkInsideTheArchive() async throws {
        let fixture = try makeFixture(symlink: true)
        defer { fixture.remove() }

        await #expect(throws: ExtensionInstaller.Failure.symbolicLink("link.json")) {
            try await ExtensionInstaller.stage(archive: fixture.archive, expecting: fixture.entry, into: fixture.staged())
        }
    }

    @Test func refusesAManifestThatDisagreesWithTheRegistry() async throws {
        let fixture = try makeFixture(manifestVersion: "2.0.0")
        defer { fixture.remove() }

        await #expect(throws: ExtensionInstaller.Failure.manifestMismatch(id: "tests.lua", version: "2.0.0")) {
            try await ExtensionInstaller.stage(archive: fixture.archive, expecting: fixture.entry, into: fixture.staged())
        }
    }

    @Test func installingFromAStagedCopyReplacesAndKeepsTheCopy() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let staged = fixture.staged()
        try await ExtensionInstaller.stage(archive: fixture.archive, expecting: fixture.entry, into: staged)

        let extensionsDir = fixture.scratch.appendingPathComponent("extensions", isDirectory: true)
        let target = extensionsDir.appendingPathComponent("tests.lua", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "old".write(to: target.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)

        try ExtensionInstaller.install(from: staged, as: fixture.entry, into: extensionsDir)

        #expect(exists(target.appendingPathComponent(LanguageManifest.fileName)))
        #expect(exists(target.appendingPathComponent("media/a.png")))
        #expect(!exists(target.appendingPathComponent("old.txt")))
        #expect(exists(staged.appendingPathComponent(LanguageManifest.fileName)))

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: extensionsDir.path)
        #expect(leftovers == ["tests.lua"])
    }

    @Test func installingIntoAMissingDirectoryCreatesIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let staged = fixture.staged()
        try await ExtensionInstaller.stage(archive: fixture.archive, expecting: fixture.entry, into: staged)

        let extensionsDir = fixture.scratch.appendingPathComponent("fresh/extensions", isDirectory: true)
        try ExtensionInstaller.install(from: staged, as: fixture.entry, into: extensionsDir)

        #expect(exists(extensionsDir.appendingPathComponent("tests.lua/extension.json")))
    }
}
