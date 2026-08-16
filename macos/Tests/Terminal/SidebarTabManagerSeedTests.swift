import Foundation
@testable import Ghostty
import Testing

/// Whether a just-initializing window's sidebar may seed itself from
/// whichever window is currently key — see `SidebarTabManager.shouldSeed`.
///
/// The bug this guards: a session restore creates windows while an
/// already-restored window is key, exactly the situation the seed was
/// built for (a genuinely new tab, about to join that window's group). But
/// a state that decoded with no `tabGroupID` is restored standalone and
/// never joins anything, so the seed's self-correction — clearing once
/// `own.tabGroup.windows.count > 1` — can never fire for it. Its sidebar
/// then permanently lists another window's tabs, and selecting or closing
/// one of those rows acts on that unrelated window instead. `shouldSeed` is
/// the one-line decision that keeps restore from ever setting the seed in
/// the first place, extracted so it is testable without a real `NSWindow`.
@MainActor
struct SidebarTabManagerSeedTests {
    /// A window created the ordinary way (Cmd-T, Cmd-N) is exactly the case
    /// the seed exists for.
    @Test func aWindowCreatedOutsideRestoreMaySeed() {
        #expect(SidebarTabManager.shouldSeed(isRestoringSession: false))
    }

    /// A window `PhantomSessionStore` is placing must never borrow another
    /// window's tab group: its own membership is decided by the saved
    /// session, not by whatever is key at the instant it is created.
    @Test func aWindowCreatedDuringRestoreNeverSeeds() {
        #expect(!SidebarTabManager.shouldSeed(isRestoringSession: true))
    }
}
