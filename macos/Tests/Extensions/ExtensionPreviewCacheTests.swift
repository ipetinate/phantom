import Foundation
@testable import Ghostty
import Testing

struct ExtensionPreviewCacheTests {
    private let root = URL(fileURLWithPath: "/Users/reader/Library/Caches/com.ipetinate.phantom/extensions", isDirectory: true)

    private func entry(id: String = "ipetinate.lua", version: String = "1.0.0", sha256: String? = nil, bytes: Int = 1065) -> ExtensionIndex.Entry {
        ExtensionIndex.Entry(
            id: id,
            name: "Lua",
            version: version,
            publisher: "ipetinate",
            summary: "",
            homepage: nil,
            minimumPhantomVersion: nil,
            contributes: [],
            languages: [],
            downloadURL: URL(string: "https://example.com/\(id).zip")!,
            sha256: sha256 ?? String(repeating: "a", count: 64),
            bytes: bytes)
    }

    private func cached(
        _ area: ExtensionPreviewCache.Cached.Area,
        id: String,
        name: String,
        verifiedAt: TimeInterval,
        bytes: Int = 0,
        marker: Bool = true
    ) -> ExtensionPreviewCache.Cached {
        let base = area == .registry
            ? ExtensionPreviewCache.registryDirectory(root: root)
            : ExtensionPreviewCache.localDirectory(root: root)
        let directory = base.appendingPathComponent(name, isDirectory: true)
        return ExtensionPreviewCache.Cached(
            area: area,
            id: id,
            directory: directory,
            marker: area == .registry && marker ? base.appendingPathComponent(name).appendingPathExtension("json") : nil,
            verifiedAt: Date(timeIntervalSince1970: verifiedAt),
            bytes: bytes)
    }

    // MARK: Paths

    @Test func theCacheLivesUnderExtensionsInTheCachesDirectory() {
        let caches = URL(fileURLWithPath: "/Users/reader/Library/Caches/com.ipetinate.phantom", isDirectory: true)
        #expect(ExtensionPreviewCache.root(cachesDir: caches) == root)
    }

    @Test func aRegistryEntryIsKeyedByIdAndVersion() {
        let lua = entry()
        #expect(ExtensionPreviewCache.directory(for: lua, root: root).path == root.path + "/registry/ipetinate.lua-1.0.0")
        #expect(ExtensionPreviewCache.markerURL(for: lua, root: root).path == root.path + "/registry/ipetinate.lua-1.0.0.json")
    }

    @Test func aLocalMirrorIsKeyedByIdVersionAndTheManifestDigestsHead() {
        let digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let directory = ExtensionPreviewCache.localDirectory(id: "acme.zig", version: "2.0.1", manifestDigest: digest, root: root)
        #expect(directory.path == root.path + "/local/acme.zig-2.0.1-0123456789ab")
    }

    @Test func theViewerIsKeyedByItsVersion() {
        #expect(ExtensionPreviewCache.viewerDirectory(version: "0.3.0", root: root).path == root.path + "/viewer/0.3.0")
    }

    @Test func aDirectoryNameReadsBackToItsIdentity() throws {
        let registry = try #require(ExtensionPreviewCache.identity(ofRegistryName: "ipetinate.lua-1.0.0"))
        #expect(registry.id == "ipetinate.lua")
        #expect(registry.version == "1.0.0")

        let dashed = try #require(ExtensionPreviewCache.identity(ofRegistryName: "my-ext-1.2.3"))
        #expect(dashed.id == "my-ext")
        #expect(dashed.version == "1.2.3")

        #expect(ExtensionPreviewCache.identity(ofRegistryName: "junk") == nil)
        #expect(ExtensionPreviewCache.identity(ofRegistryName: "ipetinate.lua-v1") == nil)
        #expect(ExtensionPreviewCache.identity(ofRegistryName: "-1.0.0") == nil)

        let local = try #require(ExtensionPreviewCache.identity(ofLocalName: "ipetinate.lua-1.0.0-0123456789ab"))
        #expect(local.id == "ipetinate.lua")
        #expect(local.version == "1.0.0")
        #expect(local.digest == "0123456789ab")
        #expect(ExtensionPreviewCache.identity(ofLocalName: "ipetinate.lua-1.0.0") == nil)
        #expect(ExtensionPreviewCache.identity(ofLocalName: "ipetinate.lua-1.0.0-xyz") == nil)
    }

    // MARK: Markers

    @Test func aMarkerRoundTripsThroughDisk() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appendingPathComponent("ipetinate.lua-1.0.0.json")
        let marker = ExtensionPreviewCache.Marker(
            sha256: ExtensionIndexTests.luaSHA, bytes: 1065, verifiedAt: Date(timeIntervalSince1970: 1_788_581_934))

        try ExtensionPreviewCache.write(marker, to: url)

        #expect(ExtensionPreviewCache.readMarker(url) == marker)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"verifiedAt\":\"2026-09-05T04:18:54Z\""))
    }

    @Test func aMarkerThatCannotVouchIsNoMarker() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appendingPathComponent("x.json")

        #expect(ExtensionPreviewCache.readMarker(url) == nil)

        try "{\"sha256\":\"short\",\"bytes\":1,\"verifiedAt\":\"2026-09-05T04:18:54Z\"}".write(to: url, atomically: true, encoding: .utf8)
        #expect(ExtensionPreviewCache.readMarker(url) == nil)

        try "{\"sha256\":\"\(ExtensionIndexTests.luaSHA)\",\"bytes\":0,\"verifiedAt\":\"2026-09-05T04:18:54Z\"}".write(to: url, atomically: true, encoding: .utf8)
        #expect(ExtensionPreviewCache.readMarker(url) == nil)

        try "not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(ExtensionPreviewCache.readMarker(url) == nil)
    }

    // MARK: Eviction

    @Test func oneVersionPerIdSurvivesUnderRegistry() {
        let older = cached(.registry, id: "ipetinate.lua", name: "ipetinate.lua-1.0.0", verifiedAt: 100, bytes: 10)
        let newer = cached(.registry, id: "ipetinate.lua", name: "ipetinate.lua-1.1.0", verifiedAt: 200, bytes: 10)
        let other = cached(.registry, id: "acme.zig", name: "acme.zig-0.1.0", verifiedAt: 50, bytes: 10)

        let plan = ExtensionPreviewCache.evictionPlan(entries: [older, newer, other], keeping: [], budget: 1000)

        #expect(plan == [older.directory, older.marker!].sorted { $0.path < $1.path })
    }

    @Test func theNewestByVerificationWinsWhateverTheVersionSays() {
        let reverified = cached(.registry, id: "ipetinate.lua", name: "ipetinate.lua-1.0.0", verifiedAt: 300)
        let stale = cached(.registry, id: "ipetinate.lua", name: "ipetinate.lua-1.1.0", verifiedAt: 200)

        let plan = ExtensionPreviewCache.evictionPlan(entries: [reverified, stale], keeping: [], budget: 1000)

        #expect(plan.contains(stale.directory))
        #expect(!plan.contains(reverified.directory))
    }

    @Test func aProtectedDirectorySurvivesANewerSibling() {
        let kept = cached(.registry, id: "ipetinate.lua", name: "ipetinate.lua-1.0.0", verifiedAt: 100)
        let newer = cached(.registry, id: "ipetinate.lua", name: "ipetinate.lua-1.1.0", verifiedAt: 200)

        let plan = ExtensionPreviewCache.evictionPlan(entries: [kept, newer], keeping: [kept.directory], budget: 1000)

        #expect(plan.contains(newer.directory))
        #expect(!plan.contains(kept.directory))
    }

    @Test func theRegistryStaysUnderItsBudgetOldestFirst() {
        let oldest = cached(.registry, id: "a.one", name: "a.one-1.0.0", verifiedAt: 10, bytes: 400)
        let middle = cached(.registry, id: "b.two", name: "b.two-1.0.0", verifiedAt: 20, bytes: 400)
        let newest = cached(.registry, id: "c.three", name: "c.three-1.0.0", verifiedAt: 30, bytes: 400)

        let plan = ExtensionPreviewCache.evictionPlan(entries: [oldest, middle, newest], keeping: [], budget: 900)

        #expect(plan.contains(oldest.directory))
        #expect(!plan.contains(middle.directory))
        #expect(!plan.contains(newest.directory))

        let tight = ExtensionPreviewCache.evictionPlan(entries: [oldest, middle, newest], keeping: [], budget: 500)
        #expect(tight.contains(oldest.directory))
        #expect(tight.contains(middle.directory))
        #expect(!tight.contains(newest.directory))

        let protected = ExtensionPreviewCache.evictionPlan(
            entries: [oldest, middle, newest], keeping: [oldest.directory], budget: 500)
        #expect(!protected.contains(oldest.directory))
        #expect(protected.contains(middle.directory))
        #expect(protected.contains(newest.directory))
    }

    @Test func aRegistryDirectoryWithoutAMarkerIsDropped() {
        let unverified = cached(.registry, id: "ipetinate.lua", name: "ipetinate.lua-1.0.0", verifiedAt: 100, marker: false)

        #expect(ExtensionPreviewCache.evictionPlan(entries: [unverified], keeping: [], budget: 1000) == [unverified.directory])
    }

    @Test func aLocalMirrorWithAnotherDigestIsDropped() {
        let older = cached(.local, id: "acme.zig", name: "acme.zig-1.0.0-000000000000", verifiedAt: 100)
        let newer = cached(.local, id: "acme.zig", name: "acme.zig-1.0.0-111111111111", verifiedAt: 200)
        let other = cached(.local, id: "acme.ada", name: "acme.ada-1.0.0-222222222222", verifiedAt: 10)

        let plan = ExtensionPreviewCache.evictionPlan(entries: [older, newer, other], keeping: [], budget: 0)

        #expect(plan == [older.directory])
    }

    @Test func nothingToEvictIsAnEmptyPlan() {
        #expect(ExtensionPreviewCache.evictionPlan(entries: [], keeping: [], budget: 0).isEmpty)
        let lone = cached(.registry, id: "ipetinate.lua", name: "ipetinate.lua-1.0.0", verifiedAt: 100, bytes: 10)
        #expect(ExtensionPreviewCache.evictionPlan(entries: [lone], keeping: [], budget: 1000).isEmpty)
    }

    // MARK: On disk

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-preview-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeExtension(id: String, version: String, into directory: URL, document: Bool = true) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = """
        {
          "schemaVersion": 1,
          "id": "\(id)",
          "name": "Lua",
          "version": "\(version)",
          "publisher": "tests",
          "contributes": { "languages": [{ "languageId": "lua", "extensions": ["lua"] }] }
        }
        """
        try manifest.write(
            to: directory.appendingPathComponent(LanguageManifest.fileName), atomically: true, encoding: .utf8)
        if document {
            try "# Lua\n".write(
                to: directory.appendingPathComponent(ExtensionCard.documentFileName), atomically: true, encoding: .utf8)
        }
    }

    @Test func aVerifiedDirectoryNeedsItsMarkerAndItsManifestToAgree() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lua = entry()
        let directory = ExtensionPreviewCache.directory(for: lua, root: root)
        try writeExtension(id: lua.id, version: lua.version, into: directory)

        #expect(ExtensionPreviewCache.verified(lua, root: root) == nil)

        try ExtensionPreviewCache.write(
            ExtensionPreviewCache.Marker(sha256: lua.sha256, bytes: lua.bytes, verifiedAt: Date()),
            to: ExtensionPreviewCache.markerURL(for: lua, root: root))
        #expect(ExtensionPreviewCache.verified(lua, root: root) == directory)

        #expect(ExtensionPreviewCache.verified(entry(sha256: String(repeating: "b", count: 64)), root: root) == nil)
        #expect(ExtensionPreviewCache.verified(entry(bytes: 1), root: root) == nil)
        #expect(ExtensionPreviewCache.verified(entry(version: "1.1.0"), root: root) == nil)

        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("link").path, withDestinationPath: LanguageManifest.fileName)
        #expect(ExtensionPreviewCache.verified(lua, root: root) == nil)
    }

    @Test func aMirrorCopiesTheInstalledExtensionUnderLocal() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installedRoot = root.appendingPathComponent("installed/lua", isDirectory: true)
        try writeExtension(id: "tests.lua", version: "1.0.0", into: installedRoot)
        let installed = InstalledExtension(id: "tests.lua", name: "Lua", version: "1.0.0", root: installedRoot)
        let digest = try #require(LanguageManifest.load(directory: installedRoot, scope: .user)).digest

        let mirror = try ExtensionPreviewCache.mirror(installed: installed, manifestDigest: digest, root: root)

        #expect(mirror == ExtensionPreviewCache.localDirectory(
            id: "tests.lua", version: "1.0.0", manifestDigest: digest, root: root))
        #expect(FileManager.default.fileExists(atPath: mirror.appendingPathComponent(ExtensionCard.documentFileName).path))
        #expect(ExtensionStore.previewState(directory: mirror, root: root)
            == .ready(document: mirror.appendingPathComponent(ExtensionCard.documentFileName), base: root))

        let again = try ExtensionPreviewCache.mirror(installed: installed, manifestDigest: digest, root: root)
        #expect(again == mirror)
        let listing = try FileManager.default.contentsOfDirectory(atPath: ExtensionPreviewCache.localDirectory(root: root).path)
        #expect(listing == [mirror.lastPathComponent])
    }

    @Test func aMirrorRefusesWhatTheInstallerWould() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installedRoot = root.appendingPathComponent("installed/lua", isDirectory: true)
        try writeExtension(id: "tests.lua", version: "1.0.0", into: installedRoot)
        try FileManager.default.createSymbolicLink(
            atPath: installedRoot.appendingPathComponent("link").path, withDestinationPath: LanguageManifest.fileName)
        let installed = InstalledExtension(id: "tests.lua", name: "Lua", version: "1.0.0", root: installedRoot)

        #expect(throws: ExtensionInstaller.Failure.symbolicLink("link")) {
            try ExtensionPreviewCache.mirror(installed: installed, manifestDigest: "abc", root: root)
        }
    }

    @Test func aDirectoryWithoutADocumentIsUnavailable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("bare", isDirectory: true)
        try writeExtension(id: "tests.lua", version: "1.0.0", into: directory, document: false)

        #expect(ExtensionStore.previewState(directory: directory, root: root) == .unavailable("The extension ships no document."))
    }

    @Test func scanningReadsWhatEvictionNeeds() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lua = entry()
        try writeExtension(id: lua.id, version: lua.version, into: ExtensionPreviewCache.directory(for: lua, root: root))
        try ExtensionPreviewCache.write(
            ExtensionPreviewCache.Marker(sha256: lua.sha256, bytes: 1065, verifiedAt: Date(timeIntervalSince1970: 1_788_581_934)),
            to: ExtensionPreviewCache.markerURL(for: lua, root: root))
        let unverified = entry(version: "0.9.0")
        try writeExtension(id: unverified.id, version: unverified.version, into: ExtensionPreviewCache.directory(for: unverified, root: root))
        let local = ExtensionPreviewCache.localDirectory(id: "acme.zig", version: "1.0.0", manifestDigest: "abcdef012345", root: root)
        try writeExtension(id: "acme.zig", version: "1.0.0", into: local)
        try FileManager.default.createDirectory(
            at: ExtensionPreviewCache.registryDirectory(root: root).appendingPathComponent(".staging-x"),
            withIntermediateDirectories: true)

        let scanned = ExtensionPreviewCache.scan(root: root).sorted { $0.directory.path < $1.directory.path }

        #expect(scanned.count == 3)
        let registry = scanned.filter { $0.area == .registry }
        #expect(registry.map(\.id) == ["ipetinate.lua", "ipetinate.lua"])
        let verified = try #require(registry.first { $0.marker != nil })
        #expect(verified.bytes == 1065)
        #expect(verified.verifiedAt == Date(timeIntervalSince1970: 1_788_581_934))
        let stale = try #require(registry.first { $0.marker == nil })
        #expect(stale.directory == ExtensionPreviewCache.directory(for: unverified, root: root))
        let mirror = try #require(scanned.first { $0.area == .local })
        #expect(mirror.id == "acme.zig")

        ExtensionPreviewCache.evict(root: root)
        #expect(!FileManager.default.fileExists(atPath: stale.directory.path))
        #expect(FileManager.default.fileExists(atPath: verified.directory.path))
        #expect(FileManager.default.fileExists(atPath: local.path))
    }

    @Test func theViewerIsCopiedOnceIntoItsVersionedDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ExtensionViewerBundle.fileNames {
            try name.write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "0.3.0\n".write(to: source.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)

        #expect(ExtensionViewerBundle.version(in: source) == "0.3.0")
        let copied = try ExtensionViewerBundle.copy(from: source, version: "0.3.0", into: root)

        #expect(copied == ExtensionPreviewCache.viewerDirectory(version: "0.3.0", root: root))
        for name in ExtensionViewerBundle.fileNames {
            #expect(try String(contentsOf: copied.appendingPathComponent(name), encoding: .utf8) == name)
        }
        #expect(ExtensionViewerBundle.html(in: copied).lastPathComponent == "viewer.html")

        try "changed".write(to: copied.appendingPathComponent("viewer.js"), atomically: true, encoding: .utf8)
        _ = try ExtensionViewerBundle.copy(from: source, version: "0.3.0", into: root)
        #expect(try String(contentsOf: copied.appendingPathComponent("viewer.js"), encoding: .utf8) == "changed")

        try "not a version".write(to: source.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        #expect(ExtensionViewerBundle.version(in: source) == nil)
    }
}
