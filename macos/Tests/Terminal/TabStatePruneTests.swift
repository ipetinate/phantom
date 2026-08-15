import Foundation
@testable import Ghostty
import Testing

/// What the tab-state directory is allowed to throw away.
///
/// The stake is asymmetric, which is why this is pinned from both sides. Keeping
/// a spent file costs sixty bytes. Deleting a live one costs the conversation a
/// tab was holding — and it costs it silently, because a restore that finds no
/// file does not fall back to an imprecise resume, it declines to resume at all
/// and the tab comes up as a bare shell.
@MainActor
struct TabStatePruneTests {
    private let surface = UUID()
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func stateFile(for id: UUID) -> URL {
        TabStateCenter.stateFileURL(for: id)
    }

    private func fragment(for id: UUID, pid: Int = 4821) -> URL {
        stateFile(for: id).deletingLastPathComponent()
            .appendingPathComponent("\(id.uuidString).\(pid).tmp")
    }

    private func prune(
        _ url: URL,
        agedDays days: Double,
        referenced: Set<UUID> = []
    ) -> Bool {
        TabStateCenter.shouldPrune(
            url,
            modified: now.addingTimeInterval(-days * 24 * 60 * 60),
            now: now,
            referencedSurfaceIDs: referenced
        )
    }

    // MARK: - Age alone

    @Test func aRecentRecordIsKept() {
        #expect(!prune(stateFile(for: surface), agedDays: 1))
        #expect(!prune(stateFile(for: surface), agedDays: 29))
    }

    /// Two days was the old horizon, and it was measured against how long a
    /// *file* stays interesting rather than how long a *tab* does.
    @Test func aRecordIdleForAWeekIsNoLongerSweptAway() {
        #expect(!prune(stateFile(for: surface), agedDays: 7))
    }

    @Test func aLongSpentRecordGoes() {
        #expect(prune(stateFile(for: surface), agedDays: 31))
    }

    // MARK: - Reference only ever spares

    /// A tab open long enough to go quiet still has its conversation when it
    /// comes back. Being named in the saved session is the honest answer to the
    /// question age was standing in for.
    @Test func aReferencedRecordSurvivesAnyAge() {
        #expect(!prune(stateFile(for: surface), agedDays: 31, referenced: [surface]))
        #expect(!prune(stateFile(for: surface), agedDays: 400, referenced: [surface]))
    }

    @Test func anUnreferencedRecordStillGoesOnAge() {
        #expect(prune(stateFile(for: surface), agedDays: 31, referenced: [UUID()]))
    }

    /// Reference cannot rescue nothing: a young file is kept either way, so the
    /// reference set is never the thing that decides to *keep* a recent record.
    @Test func referenceDoesNotChangeTheAnswerForARecentRecord() {
        #expect(!prune(stateFile(for: surface), agedDays: 1, referenced: []))
        #expect(!prune(stateFile(for: surface), agedDays: 1, referenced: [surface]))
    }

    // MARK: - The emptiness trap

    /// `referencedSurfaceIDs` returns an empty set for a session file that is
    /// missing, unreadable, or written by a newer build — and an empty set means
    /// "this tells you nothing", never "nothing is referenced".
    ///
    /// Read the wrong way round, the moment the saved session were in trouble
    /// would be the moment every session id got deleted, which is exactly when
    /// they are least replaceable. So emptiness has to degrade to the age
    /// horizon alone, matching the behavior from before the check existed.
    @Test func anEmptySetNeverWidensWhatIsDeleted() {
        for days in [0.0, 1, 7, 29, 29.9] {
            #expect(
                !prune(stateFile(for: surface), agedDays: days, referenced: []),
                "\(days) days old was deleted on an empty reference set")
        }
    }

    /// The other half of the same guarantee: with nothing known, the sweep is
    /// neither wider nor narrower than age alone.
    @Test func anEmptySetIsExactlyTheAgeHorizon() {
        let url = stateFile(for: surface)
        for days in [0.0, 15, 29, 31, 90] {
            #expect(
                prune(url, agedDays: days, referenced: []) == (days > 30),
                "\(days) days old did not match the age horizon")
        }
    }

    // MARK: - Write fragments answer to their own horizon

    /// A fragment is never identity — nothing reads it and no session is named
    /// in it — so it is swept on its own short horizon rather than loitering for
    /// a month behind the records that matter.
    @Test func aFreshFragmentIsLeftAloneAndAnAbandonedOneGoes() {
        let leftover = fragment(for: surface)
        #expect(!prune(leftover, agedDays: 0))
        #expect(prune(leftover, agedDays: 1))
    }

    /// And a fragment is never spared by reference, even when it is named after
    /// a surface the session still holds — the surface's *record* is what
    /// carries the id, not the half-written file beside it.
    @Test func aFragmentIsNotSparedByReference() {
        #expect(prune(fragment(for: surface), agedDays: 1, referenced: [surface]))
    }

    // MARK: - Anything else in the directory

    /// A name that is neither a surface id nor a fragment cannot be matched
    /// against the session, so it answers to age alone — which is what it did
    /// before any of this.
    @Test func anUnrecognizedNameFallsBackToAge() {
        let stray = TabStateCenter.stateDir.appendingPathComponent("notes.txt")
        #expect(!prune(stray, agedDays: 1))
        #expect(prune(stray, agedDays: 31))
    }
}
