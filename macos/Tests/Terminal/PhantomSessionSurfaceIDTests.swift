import Foundation
@testable import Ghostty
import Testing

/// Harvesting the surface ids out of a saved session without decoding it.
///
/// This exists so the tab-state prune can ask "is this file still part of the
/// session?" instead of only "is this file old?". Age answers the wrong
/// question: an mtime records when an *agent* last wrote, not when the *tab*
/// was last used, so a tab left open beside a quiet agent aged out and lost
/// its session id, and came back as a bare shell without attempting a resume.
///
/// Nothing here decodes a `TerminalRestorableState`, and nothing here may
/// start to — decoding reaches `SurfaceView.init(from:)`, which builds a live
/// libghostty surface, forks a login shell and fires an agent resume, inside a
/// test host that *is* Phantom.app. Reading the ids off the raw JSON is the
/// whole point of the function under test.
struct PhantomSessionSurfaceIDTests {
    private func data(_ object: Any) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// One terminal, in the current envelope — the ordinary case.
    @Test func aSingleSurfaceIsFound() {
        let id = "43966D33-A30C-4CA7-8070-AECFE9429A31"
        let json: [String: Any] = [
            "version": 1,
            "states": [[
                "focusedSurface": id,
                "surfaceTree": ["version": 1, "root": ["view": ["uuid": id, "title": "~"]]],
            ]],
        ]

        #expect(PhantomSessionStore.surfaceIDs(in: data(json)) == [UUID(uuidString: id)!])
    }

    /// A split tree: the ids that matter are nested several levels down, which
    /// is why the walk is recursive rather than a look at a known path.
    @Test func everySurfaceInASplitTreeIsFound() {
        let left = "11111111-1111-4111-8111-111111111111"
        let right = "22222222-2222-4222-8222-222222222222"
        let json: [String: Any] = [
            "version": 1,
            "states": [[
                "surfaceTree": ["root": ["split": [
                    "left": ["view": ["uuid": left]],
                    "right": ["split": [
                        "left": ["view": ["uuid": right]],
                        "right": ["view": ["uuid": left]],
                    ]],
                ]]],
            ]],
        ]

        #expect(
            PhantomSessionStore.surfaceIDs(in: data(json))
                == [UUID(uuidString: left)!, UUID(uuidString: right)!]
        )
    }

    /// Several windows, each with its own terminal, all counted.
    @Test func surfacesAcrossWindowsAreAllFound() {
        let ids = [
            "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa",
            "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb",
            "cccccccc-3333-4333-8333-cccccccccccc",
        ]
        let json: [String: Any] = [
            "version": 1,
            "states": ids.map { ["surfaceTree": ["root": ["view": ["uuid": $0]]]] },
        ]

        #expect(PhantomSessionStore.surfaceIDs(in: data(json)) == Set(ids.map { UUID(uuidString: $0)! }))
    }

    /// The original bare-array file, which older installs still have on disk.
    /// The prune must not start deleting their state files just because the
    /// envelope is the previous shape.
    @Test func theUnversionedArrayShapeIsStillRead() {
        let id = "44444444-4444-4444-8444-444444444444"
        let json: [Any] = [["surfaceTree": ["root": ["view": ["uuid": id]]]]]

        #expect(PhantomSessionStore.surfaceIDs(in: data(json)) == [UUID(uuidString: id)!])
    }

    /// `focusedSurface` repeats an id a `uuid` key already supplied, so the
    /// set does not grow — this pins that only ids surfaces *define* are
    /// collected, not every field that happens to hold one.
    @Test func aRepeatedIdIsCountedOnce() {
        let id = "55555555-5555-4555-8555-555555555555"
        let json: [String: Any] = [
            "version": 1,
            "states": [[
                "focusedSurface": id,
                "surfaceTree": ["root": ["view": ["uuid": id]]],
            ]],
        ]

        #expect(PhantomSessionStore.surfaceIDs(in: data(json)).count == 1)
    }

    /// A file this build cannot parse tells the caller nothing. It must come
    /// back empty rather than throwing, and the caller's contract is that
    /// empty means "no information" — never "nothing is referenced, delete
    /// freely".
    @Test func unparseableDataYieldsNothing() {
        #expect(PhantomSessionStore.surfaceIDs(in: Data("not json".utf8)).isEmpty)
        #expect(PhantomSessionStore.surfaceIDs(in: Data()).isEmpty)
    }

    /// The session file is user-writable and outlives any build of the app, so
    /// a `uuid` that is not one is a shape to survive, not to trust.
    @Test func aUuidKeyHoldingSomethingElseIsIgnored() {
        let json: [String: Any] = [
            "version": 1,
            "states": [
                ["surfaceTree": ["root": ["view": ["uuid": "not-a-uuid"]]]],
                ["surfaceTree": ["root": ["view": ["uuid": 42]]]],
            ],
        ]

        #expect(PhantomSessionStore.surfaceIDs(in: data(json)).isEmpty)
    }

    /// Deep nesting costs a truncated answer, not the stack. Built past the
    /// ceiling on purpose: the id at the bottom is unreachable, and the one
    /// within reach is still found, which is the behaviour that keeps a
    /// hand-edited file from taking the app down.
    @Test func pathologicalNestingTruncatesInsteadOfCrashing() {
        let shallow = "66666666-6666-4666-8666-666666666666"
        let deep = "77777777-7777-4777-8777-777777777777"

        var nested: Any = ["view": ["uuid": deep]]
        for _ in 0..<200 { nested = ["wrapped": nested] }

        let json: [String: Any] = [
            "version": 1,
            "states": [[
                "surfaceTree": ["root": ["view": ["uuid": shallow]]],
                "deep": nested,
            ]],
        ]

        let found = PhantomSessionStore.surfaceIDs(in: data(json))
        #expect(found.contains(UUID(uuidString: shallow)!))
        #expect(!found.contains(UUID(uuidString: deep)!))
    }

    /// A session with no terminals in it references nothing, which is a
    /// different fact from a file that could not be read — both come back
    /// empty, and the caller must not tell them apart by the result alone.
    @Test func anEmptySessionReferencesNothing() {
        let json: [String: Any] = ["version": 1, "states": []]

        #expect(PhantomSessionStore.surfaceIDs(in: data(json)).isEmpty)
    }
}
