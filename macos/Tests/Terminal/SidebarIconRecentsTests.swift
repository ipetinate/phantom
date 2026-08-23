import Foundation
@testable import Ghostty
import Testing

/// The Recents row: ten slots, newest first, no repeats, and it survives a
/// round trip through the defaults.
///
/// Run against a suite of the test's own, torn down after — the
/// `SidebarWidthOverrideTests` idiom — so no test leaves a Recents row behind
/// on the machine it ran on.
struct SidebarIconRecentsTests {
    private func withStore(_ body: (SidebarIconRecents) throws -> Void) throws {
        let name = "SidebarIconRecentsTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        try body(SidebarIconRecents(defaults: defaults))
    }

    @Test func aChoiceRoundTripsThroughTheDefaults() throws {
        try withStore { recents in
            recents.record("folder")

            #expect(recents.icons == ["folder"])
        }
    }

    @Test func theNewestChoiceComesFirst() throws {
        try withStore { recents in
            for icon in ["folder", "flame", "bolt"] { recents.record(icon) }

            #expect(recents.icons == ["bolt", "flame", "folder"])
        }
    }

    /// The whole point of the row is picking something again, and a second
    /// copy would spend one of the ten slots restating the first.
    @Test func repickingMovesToTheFrontInsteadOfDuplicating() throws {
        try withStore { recents in
            for icon in ["folder", "flame", "bolt"] { recents.record(icon) }
            recents.record("folder")

            #expect(recents.icons == ["folder", "bolt", "flame"])
        }
    }

    @Test func theRowStopsAtTen() throws {
        try withStore { recents in
            let chosen = (1...14).map { "\($0).circle" }
            for icon in chosen { recents.record(icon) }

            #expect(recents.icons.count == SidebarIconRecents.limit)
            #expect(recents.icons == Array(chosen.suffix(10).reversed()))
        }
    }

    /// The selection is one string in three forms, and the reader who just
    /// picked 🔥 expects to find 🔥 — not the last symbol they touched.
    @Test func everyFormOfAnIconIsRecorded() throws {
        try withStore { recents in
            for icon in ["🔥", SidebarIconID.id(for: .claude), "rectangle.3.group"] {
                recents.record(icon)
            }

            #expect(recents.icons == ["rectangle.3.group", SidebarIconID.id(for: .claude), "🔥"])
        }
    }

    /// The tab editor opens with no icon at all, and saving it must not
    /// record one.
    @Test func blankIsNotAChoice() throws {
        try withStore { recents in
            recents.record("")
            recents.record("   ")

            #expect(recents.icons.isEmpty)
        }
    }

    /// A stored list outlives the build that wrote it. What this build cannot
    /// draw is dropped, because an empty box in the picker is
    /// indistinguishable from a broken sheet.
    @Test func whatThisBuildCannotDrawIsNotOffered() {
        let kept = SidebarIconRecents.drawable([
            "folder",
            "🔥",
            SidebarIconID.id(for: .claude),
            "agent:aider",
            "not.a.real.symbol.name.from.a.newer.macos",
            "",
        ])

        #expect(kept == ["folder", "🔥", SidebarIconID.id(for: .claude)])
    }

    /// The merge is pure, so the cap and the move-to-front hold without a
    /// defaults suite in the way.
    @Test func theMergeIsIndependentOfStorage() {
        #expect(SidebarIconRecents.recording("b", into: ["a", "b", "c"]) == ["b", "a", "c"])
        #expect(SidebarIconRecents.recording("", into: ["a"]) == ["a"])

        let full = (1...10).map { "\($0).circle" }
        let merged = SidebarIconRecents.recording("star", into: full)

        #expect(merged.count == SidebarIconRecents.limit)
        #expect(merged.first == "star")
        #expect(!merged.contains("10.circle"))
    }
}
