import Foundation
@testable import Ghostty
import Testing

/// When the welcome window opens by itself.
///
/// Two facts kept apart: what this reader has been shown, and whether they want
/// it every time. The tests are about the reader who upgrades — the case a
/// boolean cannot answer, because a boolean written by an older build cannot
/// tell somebody who has seen the panel from somebody whose app never had one.
struct WelcomeShownRecordTests {
    @Test func aFirstLaunchOpensIt() {
        #expect(WelcomeShownRecord.opensAtLaunch(shownRevision: 0, showsAtLaunch: false))
    }

    @Test func havingSeenThisRevisionDoesNotOpenItAgain() {
        #expect(!WelcomeShownRecord.opensAtLaunch(
            shownRevision: WelcomeShownRecord.currentRevision, showsAtLaunch: false))
    }

    /// The upgrade: a reader on an earlier Phantom has a revision below this
    /// one — 0, because the key did not exist — and is shown the window once.
    @Test func anEarlierRevisionOpensItOnce() {
        #expect(WelcomeShownRecord.opensAtLaunch(shownRevision: 0, showsAtLaunch: false))
        #expect(WelcomeShownRecord.currentRevision > 0)
    }

    /// A record from a build newer than this one reads as already shown. The
    /// opposite of what `LanguageTrustStore` does with a record it cannot
    /// read, and correct for the opposite reason: there an unreadable record
    /// must not stand in for permission, here the worst case is a window
    /// nobody asked for.
    @Test func aRevisionFromTheFutureDoesNotOpenIt() {
        #expect(!WelcomeShownRecord.opensAtLaunch(
            shownRevision: WelcomeShownRecord.currentRevision + 5, showsAtLaunch: false))
    }

    /// The switch wins over having seen it, which is the whole point of having
    /// a switch.
    @Test func theStartupSwitchOpensItEveryTime() {
        #expect(WelcomeShownRecord.opensAtLaunch(
            shownRevision: WelcomeShownRecord.currentRevision, showsAtLaunch: true))
        #expect(WelcomeShownRecord.opensAtLaunch(
            shownRevision: WelcomeShownRecord.currentRevision + 5, showsAtLaunch: true))
    }

    /// The two keys are distinct strings; one key holding both facts is how a
    /// reader who ticked the switch would also be told they had never seen it.
    @Test func theTwoFactsAreKeptApart() {
        #expect(WelcomeShownRecord.revisionKey != WelcomeShownRecord.showsAtLaunchKey)
        #expect(WelcomeShownRecord.revisionKey == "WelcomeShownRevision")
        #expect(WelcomeShownRecord.showsAtLaunchKey == "WelcomeShowsAtLaunch")
    }
}
