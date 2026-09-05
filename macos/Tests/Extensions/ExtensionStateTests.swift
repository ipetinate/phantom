import Foundation
@testable import Ghostty
import Testing

struct ExtensionStateTests {
    @Test func nothingOnDiskIsNotInstalled() {
        #expect(ExtensionStore.state(installedVersion: nil, available: "1.0.0") == .notInstalled)
    }

    @Test func theSameVersionIsInstalled() {
        #expect(
            ExtensionStore.state(installedVersion: "1.0.0", available: "1.0.0")
                == .installed(version: "1.0.0"))
    }

    @Test func aNewerIndexOffersAnUpdate() {
        #expect(
            ExtensionStore.state(installedVersion: "1.0.0", available: "1.0.1")
                == .updateAvailable(installed: "1.0.0", available: "1.0.1"))
        #expect(
            ExtensionStore.state(installedVersion: "1.9.9", available: "1.10.0")
                == .updateAvailable(installed: "1.9.9", available: "1.10.0"))
    }

    @Test func anOlderIndexNeverOffersADowngrade() {
        #expect(
            ExtensionStore.state(installedVersion: "2.0.0", available: "1.0.0")
                == .installed(version: "2.0.0"))
        #expect(
            ExtensionStore.state(installedVersion: "1.10.0", available: "1.9.9")
                == .installed(version: "1.10.0"))
    }

    @Test func anUnreadableVersionOnEitherSideStaysInstalled() {
        #expect(
            ExtensionStore.state(installedVersion: "dev", available: "1.0.0")
                == .installed(version: "dev"))
        #expect(
            ExtensionStore.state(installedVersion: "1.0.0", available: "latest")
                == .installed(version: "1.0.0"))
    }
}

@MainActor
struct ExtensionStoreInstalledScanTests {
    private func makeExtensionsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-extensions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ manifest: String, into directory: URL, named name: String) throws {
        let root = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try manifest.write(
            to: root.appendingPathComponent(LanguageManifest.fileName),
            atomically: true,
            encoding: .utf8)
    }

    private func manifest(id: String?, name: String, version: String) -> String {
        let idLine = id.map { "\"id\": \"\($0)\"," } ?? ""
        return """
        {
          "schemaVersion": 1,
          \(idLine)
          "name": "\(name)",
          "version": "\(version)",
          "publisher": "tests",
          "contributes": { "languages": [{ "languageId": "\(name.lowercased())", "extensions": ["x"] }] }
        }
        """
    }

    private func entry(id: String, version: String) -> ExtensionIndex.Entry {
        ExtensionIndex.Entry(
            id: id,
            name: id,
            version: version,
            publisher: "tests",
            summary: "",
            homepage: nil,
            minimumPhantomVersion: nil,
            contributes: [],
            languages: [],
            downloadURL: URL(string: "https://example.com/\(id).zip")!,
            sha256: String(repeating: "0", count: 64),
            bytes: 1)
    }

    @Test func listsEveryReadableManifestSortedByName() throws {
        let directory = try makeExtensionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(manifest(id: "tests.zeta", name: "Zeta", version: "1.0.0"), into: directory, named: "zeta")
        try write(manifest(id: "tests.alpha", name: "alpha", version: "2.3.4"), into: directory, named: "alpha")
        try write(manifest(id: "tests.mid", name: "Mid", version: "0.1.0"), into: directory, named: "mid")

        let store = ExtensionStore(extensionsDir: directory)

        #expect(store.installed.map(\.id) == ["tests.alpha", "tests.mid", "tests.zeta"])
        #expect(store.installed.map(\.version) == ["2.3.4", "0.1.0", "1.0.0"])
        #expect(store.installed.first?.root.lastPathComponent == "alpha")
    }

    @Test func skipsWhatItCannotName() throws {
        let directory = try makeExtensionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(manifest(id: "tests.good", name: "Good", version: "1.0.0"), into: directory, named: "good")
        try write("{ not json", into: directory, named: "broken")
        try write(manifest(id: nil, name: "Anonymous", version: "1.0.0"), into: directory, named: "anonymous")
        try write(manifest(id: "tests.hidden", name: "Hidden", version: "1.0.0"), into: directory, named: ".hidden")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true)
        try "loose".write(
            to: directory.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)

        let store = ExtensionStore(extensionsDir: directory)

        #expect(store.installed.map(\.id) == ["tests.good"])
    }

    @Test func twoDirectoriesWithOneIdKeepTheFirstByDirectoryName() throws {
        let directory = try makeExtensionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(manifest(id: "tests.same", name: "Later", version: "2.0.0"), into: directory, named: "b-copy")
        try write(manifest(id: "tests.same", name: "Earlier", version: "1.0.0"), into: directory, named: "a-copy")

        let store = ExtensionStore(extensionsDir: directory)

        #expect(store.installed.count == 1)
        #expect(store.installed.first?.version == "1.0.0")
    }

    @Test func aMissingDirectoryIsAnEmptyList() throws {
        let directory = try makeExtensionsDirectory()
        try FileManager.default.removeItem(at: directory)

        let store = ExtensionStore(extensionsDir: directory)

        #expect(store.installed.isEmpty)
    }

    @Test func stateReadsTheInstalledVersionByEntryId() throws {
        let directory = try makeExtensionsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(manifest(id: "tests.lua", name: "Lua", version: "1.0.0"), into: directory, named: "lua")

        let store = ExtensionStore(extensionsDir: directory)

        #expect(store.state(for: entry(id: "tests.lua", version: "1.0.0")) == .installed(version: "1.0.0"))
        #expect(
            store.state(for: entry(id: "tests.lua", version: "1.1.0"))
                == .updateAvailable(installed: "1.0.0", available: "1.1.0"))
        #expect(store.state(for: entry(id: "tests.lua", version: "0.9.0")) == .installed(version: "1.0.0"))
        #expect(store.state(for: entry(id: "tests.other", version: "1.0.0")) == .notInstalled)
    }
}
