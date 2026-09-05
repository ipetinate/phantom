import Foundation
@testable import Ghostty
import Testing

struct CachesDirTests {
    private let base = URL(fileURLWithPath: "/Users/reader/Library/Caches", isDirectory: true)

    @Test func theReleaseBuildCachesUnderItsBundleId() {
        let dir = GuiConfigStore.cachesDir(bundleID: PhantomBuild.releaseBundleID, base: base)
        #expect(dir.path == "/Users/reader/Library/Caches/com.ipetinate.phantom")
        #expect(dir.hasDirectoryPath)
    }

    @Test func anotherBuildCachesBesideTheReleaseOne() {
        let dir = GuiConfigStore.cachesDir(bundleID: "com.ipetinate.phantom.debug", base: base)
        #expect(dir.path == "/Users/reader/Library/Caches/com.ipetinate.phantom.debug")
    }

    @MainActor
    @Test func anOverrideIsAnsweredAsGiven() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-caches-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let config = scratch.appendingPathComponent("config", isDirectory: true)
        let caches = scratch.appendingPathComponent("caches", isDirectory: true)

        let store = GuiConfigStore(configDir: config, cachesDir: caches)

        #expect(store.cachesDirURL == caches)
        #expect(store.extensionsDirURL == config.appendingPathComponent("extensions", isDirectory: true))
    }
}
