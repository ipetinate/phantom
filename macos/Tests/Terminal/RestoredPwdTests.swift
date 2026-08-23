import Testing
@testable import Ghostty

/// Where a restored surface's `pwd` starts, and the ratchet the rule stops.
///
/// `encode` writes the live property, and the live property is nil until the
/// shell's first OSC report — about a second after spawn. A session saved
/// inside that gap recorded nil, the next restore spawned every shell in the
/// home directory, and each fast close/restore cycle walked more of the
/// session home. Watched happen: a session of project terminals reduced to a
/// column of `~` rows over a morning of restore cycles.
struct RestoredPwdTests {
    @Test func theSavedDirectorySeedsASilentShell() {
        let pwd = Ghostty.SurfaceView.seededPwd(
            live: nil, saved: "/Users/reader/project")
        #expect(pwd == "/Users/reader/project")
    }

    @Test func theShellsOwnReportAlwaysWins() {
        let pwd = Ghostty.SurfaceView.seededPwd(
            live: "/Users/reader/project/sub", saved: "/Users/reader/project")
        #expect(pwd == "/Users/reader/project/sub")
    }

    @Test func nothingKnownStaysNothing() {
        #expect(Ghostty.SurfaceView.seededPwd(live: nil, saved: nil) == nil)
    }
}
