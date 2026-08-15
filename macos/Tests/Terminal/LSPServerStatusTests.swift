@testable import Ghostty
import Testing

/// What a server's status says about it — whether it's worth a banner, and
/// what the banner should read.
struct LSPServerStatusTests {
    /// `starting` and `running` are what a healthy server looks like; every
    /// other case is something that went wrong and should reach the user.
    @Test func onlyTheUnhealthyStatesAreFailures() {
        #expect(!LSPServerStatus.starting.isFailure)
        #expect(!LSPServerStatus.running.isFailure)

        #expect(LSPServerStatus.notInstalled.isFailure)
        #expect(LSPServerStatus.notApproved.isFailure)
        #expect(LSPServerStatus.failedToStart(reason: "boom").isFailure)
        #expect(LSPServerStatus.crashed(status: 1).isFailure)
        #expect(LSPServerStatus.unresponsive.isFailure)
    }

    /// A crash with no exit status (killed at a timeout, say) still reads
    /// as a sentence rather than dangling on a missing number.
    @Test func aCrashWithNoStatusStillSummarizes() {
        #expect(LSPServerStatus.crashed(status: nil).summary == "exited")
        #expect(LSPServerStatus.crashed(status: 137).summary == "exited (status 137)")
    }

    /// The reason a server failed to start is carried through verbatim —
    /// it's the one piece of information the whole feature exists to
    /// surface.
    @Test func theFailureReasonSurvivesIntoTheSummary() {
        #expect(LSPServerStatus.failedToStart(reason: "JAVA_HOME not set").summary.contains("JAVA_HOME not set"))
    }

    /// A withheld server is not a broken one, and the sentence has to say so
    /// — with the way back, since the decision is reversible from Settings
    /// and nowhere else. A reader told "didn't start" would go looking for a
    /// fault in a server that is behaving correctly by not existing.
    @Test func aWithheldServerSaysItIsAPermissionAndNotAFault() {
        let summary = LSPServerStatus.notApproved.summary
        #expect(summary.contains("approved"))
        #expect(summary.contains("Settings"))
        #expect(!summary.contains("didn't start"))
    }
}
