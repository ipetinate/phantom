import Foundation
@testable import Ghostty
import Testing

/// Carrying state across when a build stops sharing its state files.
///
/// The debug and release builds wrote the same `sidebar-groups.json` because
/// its directory was the release bundle identifier, spelled out. Separating
/// them is only safe if what is already on disk comes along, and the failure
/// modes of a migration are worse than the bug it fixes: a copy that runs
/// twice, or runs over state the build had already written for itself, loses
/// work rather than reordering tabs. So the interesting cases here are all
/// about what the migration *refuses* to do.
@MainActor
struct PhantomStateFileTests {
    /// A throwaway directory to hang both locations off, so a test never sees
    /// another test's files or the real Application Support.
    private func sandbox() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-state-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The debug build's case: nothing at its own path yet, so it inherits
    /// what the two builds were sharing — and the shared file stays put, which
    /// is the whole reason this is a copy. The target's directory does not
    /// exist beforehand either; creating it is part of the job.
    @Test func copiesTheSharedFileWhenThisBuildHasNoneYet() throws {
        let root = sandbox()
        let shared = root.appendingPathComponent("com.ipetinate.phantom/sidebar-groups.json")
        let mine = root.appendingPathComponent("com.ipetinate.phantom.debug/sidebar-groups.json")
        try FileManager.default.createDirectory(
            at: shared.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("shared state".utf8).write(to: shared)

        PhantomStateFile.migrate(from: shared, to: mine)

        #expect(try String(contentsOf: mine, encoding: .utf8) == "shared state")
        #expect(try String(contentsOf: shared, encoding: .utf8) == "shared state")
    }

    /// The one that would hurt: a build that already has its own state must
    /// keep it. This runs on every launch, so a migration willing to overwrite
    /// would replace the groups edited five minutes ago with whatever the
    /// builds last shared — every single time the app started.
    @Test func leavesStateThisBuildAlreadyHasAlone() throws {
        let root = sandbox()
        let shared = root.appendingPathComponent("com.ipetinate.phantom/sidebar-groups.json")
        let mine = root.appendingPathComponent("com.ipetinate.phantom.debug/sidebar-groups.json")
        for url in [shared, mine] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try Data("stale shared state".utf8).write(to: shared)
        try Data("my newer state".utf8).write(to: mine)

        PhantomStateFile.migrate(from: shared, to: mine)

        #expect(try String(contentsOf: mine, encoding: .utf8) == "my newer state")
        #expect(try String(contentsOf: shared, encoding: .utf8) == "stale shared state")
    }

    /// The release build, whose two paths are one file: the hardcoded location
    /// this fork always wrote *is* its bundle identifier. Nothing may happen —
    /// not a truncation, not a duplicate, and not the throw a self-copy would
    /// produce.
    @Test func theReleaseBuildsIdenticalPathIsANoOp() throws {
        let root = sandbox()
        let shared = root.appendingPathComponent("sidebar-groups.json")
        try Data("release state".utf8).write(to: shared)

        PhantomStateFile.migrate(from: shared, to: shared)

        #expect(try String(contentsOf: shared, encoding: .utf8) == "release state")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [
            "sidebar-groups.json"
        ])
    }

    /// The same file reached by a path spelled differently, which is what the
    /// standardization in the equality guard is for. Same requirement: one
    /// file, unchanged.
    @Test func anEquivalentPathSpellingIsAlsoANoOp() throws {
        let root = sandbox()
        let shared = root.appendingPathComponent("sidebar-groups.json")
        try Data("release state".utf8).write(to: shared)

        PhantomStateFile.migrate(
            from: URL(fileURLWithPath: root.path + "/./sidebar-groups.json"),
            to: shared
        )

        #expect(try String(contentsOf: shared, encoding: .utf8) == "release state")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [
            "sidebar-groups.json"
        ])
    }

    /// A first launch with nothing to inherit. Entirely inert: no file, and
    /// not even the directory, so a store that finds nothing is a store that
    /// has never run rather than one whose migration half-happened.
    @Test func aMissingSharedFileIsHarmless() {
        let root = sandbox()
        let shared = root.appendingPathComponent("com.ipetinate.phantom/sidebar-groups.json")
        let mine = root.appendingPathComponent("com.ipetinate.phantom.debug/sidebar-groups.json")

        PhantomStateFile.migrate(from: shared, to: mine)

        #expect(!FileManager.default.fileExists(atPath: mine.path))
        #expect(!FileManager.default.fileExists(atPath: mine.deletingLastPathComponent().path))
    }

    /// End to end, against the store rather than against bytes: what the
    /// migration copies is what `SidebarGroupStore` comes up holding.
    ///
    /// Written by a real store instead of a hand-built JSON string so the test
    /// cannot quietly drift from the shape the store encodes, and the
    /// assertion is on `tabOrder` as much as on the groups — the shuffled tab
    /// order is the symptom the reader actually saw.
    @Test func theStoreComesUpOnTheMigratedState() async throws {
        let root = sandbox()
        let shared = root.appendingPathComponent("com.ipetinate.phantom/sidebar-groups.json")
        let mine = root.appendingPathComponent("com.ipetinate.phantom.debug/sidebar-groups.json")
        try FileManager.default.createDirectory(
            at: shared.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let surfaceId = UUID()
        let before = SidebarGroupStore(fileURL: shared)
        let group = before.createGroup(name: "Aurora")
        before.registerNewTab(surfaceId: surfaceId, atStart: false)

        /// The store's writes are debounced by 500ms; this waits for the one
        /// the two calls above coalesce into.
        try await Task.sleep(for: .milliseconds(700))

        PhantomStateFile.migrate(from: shared, to: mine)
        let after = SidebarGroupStore(fileURL: mine)

        #expect(after.groups.map(\.id) == [group.id])
        #expect(after.tabOrder == [surfaceId])
        #expect(FileManager.default.fileExists(atPath: shared.path))
    }
}
