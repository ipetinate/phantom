import AppKit
import Foundation
@testable import Ghostty
import Testing

/// Whether a terminal's splits reach the session file and come back.
///
/// Written because the report — "quit with a split, reopen, one terminal" —
/// does not say which side lost it, and the two sides fail in ways that look
/// the same from the outside. This exercises the JSON the store actually
/// writes and reads: `InternalState`, encoded and decoded the way `saveNow`
/// and `load` do it.
///
/// `MockView` stands in for `Ghostty.SurfaceView`, as it must — see
/// `TerminalRestorableTests` for why decoding the real one in a test builds a
/// live surface and forks a shell inside the test host. The envelope, the
/// tree and the node encoding are the same either way, and those are what
/// this is about.
@MainActor
struct PhantomSessionSplitTests {
    private func state(
        surfaceTree: SplitTree<MockView>
    ) -> TerminalRestorableState.InternalState<MockView> {
        .init(
            focusedSurface: nil,
            surfaceTree: surfaceTree,
            effectiveFullscreenMode: nil,
            tabColor: nil,
            titleOverride: nil,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            tabGroupID: nil,
            tabIndex: nil,
            isSelectedTab: nil,
            isFullscreen: false,
            editorGrid: nil)
    }

    /// The save side. A split has to reach the file as a split, under the
    /// key the decode looks for.
    @Test func aSplitTerminalIsWrittenAsASplit() throws {
        let (tree, _, _) = try SplitTreeTests.makeHorizontalSplit()

        let data = try JSONEncoder().encode(state(surfaceTree: tree))
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"split\""))
        #expect(json.contains("\"direction\""))
        #expect(json.contains("\"ratio\""))
    }

    /// The load side. Both surfaces have to come back, still arranged.
    @Test func aSplitTerminalIsReadBackAsASplit() throws {
        let (tree, first, second) = try SplitTreeTests.makeHorizontalSplit()

        let data = try JSONEncoder().encode(state(surfaceTree: tree))
        let decoded = try JSONDecoder()
            .decode(TerminalRestorableState.InternalState<MockView>.self, from: data)

        #expect(decoded.surfaceTree.isSplit)
        #expect(decoded.surfaceTree.count == 2)
        #expect(decoded.surfaceTree.contains { $0.id == first.id })
        #expect(decoded.surfaceTree.contains { $0.id == second.id })
    }

    /// A window with no split still writes a bare leaf, which is what the
    /// live session file holds for every terminal in it — the contrast that
    /// tells a lost split from one that was never taken.
    @Test func anUnsplitTerminalIsWrittenAsALeaf() throws {
        let tree = SplitTree<MockView>(view: MockView())

        let data = try JSONEncoder().encode(state(surfaceTree: tree))
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"view\""))
        #expect(!json.contains("\"split\""))
    }

    /// Mirrors the store's own envelope, which is private to it.
    private struct Envelope: Encodable {
        let version: Int
        let states: [TerminalRestorableState.InternalState<MockView>]
    }

    /// The count `saveNow` guards on is windows, not surfaces. A split must
    /// not read as a second window, or a session of one split terminal would
    /// look like it grew — and `shouldWrite` compares those counts.
    @Test func aSplitCountsAsOneSavedWindow() throws {
        let (tree, _, _) = try SplitTreeTests.makeHorizontalSplit()
        let data = try JSONEncoder().encode(
            Envelope(version: 1, states: [state(surfaceTree: tree)]))

        guard case .readable(let count, let isVersioned) = PhantomSessionStore.inspect(data) else {
            Issue.record("an envelope holding one split window did not read as a session")
            return
        }
        #expect(count == 1)
        #expect(isVersioned)
    }

    /// The prune reads surface ids straight out of the raw JSON, and the
    /// comment there claims it reaches the ones nested inside a split. A
    /// surface it misses loses its tab-state file, and that tab comes back a
    /// bare shell with no agent session to resume.
    ///
    /// Written against literal JSON rather than an encoded `MockView`,
    /// because the mock records its id under `id` while a real surface
    /// records it under `uuid` — and `uuid` is the key the harvest reads.
    /// What is asserted here is the shape the app actually writes.
    @Test func bothSurfacesOfASplitAreFoundInTheRawFile() throws {
        let first = UUID()
        let second = UUID()
        let json = """
        {"version": 1, "states": [{"surfaceTree": {"version": 1, "root": {"split": {
          "direction": {"horizontal": {}}, "ratio": 0.5,
          "left": {"view": {"uuid": "\(first.uuidString)", "pwd": "/", "title": "a",
                            "isUserSetTitle": false}},
          "right": {"view": {"uuid": "\(second.uuidString)", "pwd": "/", "title": "b",
                             "isUserSetTitle": false}}}}}}]}
        """
        let data = try #require(json.data(using: .utf8))

        let ids = PhantomSessionStore.surfaceIDs(in: data)
        #expect(ids.contains(first))
        #expect(ids.contains(second))
    }
}
