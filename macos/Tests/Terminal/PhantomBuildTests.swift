import Foundation
@testable import Ghostty
import Testing

/// Which build is running, and what it may call the files it writes into other
/// applications' directories.
///
/// The rule exists because the same leak has been found four times: the session
/// store, the MCP socket, the agent entry, the configuration directory — and
/// then the hook scripts, which are the worst of them, because they live in the
/// agent's own directory rather than in this app's. Two builds wrote one file
/// at one path, each launch rewriting it with its own text, and an uninstall
/// from either took the other's hooks with it.
struct PhantomBuildTests {
    // MARK: The variant

    @Test func theReleaseBuildHasNoVariant() {
        #expect(PhantomBuild.variant(forBundleID: "com.ipetinate.phantom") == nil)
    }

    @Test func aDebugBuildIsToldApartByItsBundleID() {
        #expect(PhantomBuild.variant(forBundleID: "com.ipetinate.phantom.debug") == "debug")
    }

    @Test func anyVariantIsRecognisedRatherThanAListOfTwo() {
        #expect(PhantomBuild.variant(forBundleID: "com.ipetinate.phantom.nightly") == "nightly")
        #expect(PhantomBuild.variant(forBundleID: "com.ipetinate.Phantom") == nil)
        #expect(PhantomBuild.variant(forBundleID: "") == nil)
    }

    // MARK: File names

    /// **The release build's paths never move.** Every reader who has installed
    /// hooks has them at these names, and a rename would leave a registered
    /// script the app no longer recognises — hooks that look uninstalled and
    /// still run.
    @Test func theReleaseBuildKeepsEveryNameItHasWritten() {
        for name in [
            "phantom-tab-state.sh", "phantom-integration.js", "phantom.ts",
        ] {
            #expect(
                PhantomBuild.fileName(name, forBundleID: "com.ipetinate.phantom") == name,
                "\(name)")
        }
    }

    /// The leading word becomes this build's own name, so the two builds write
    /// two files and register two hooks.
    @Test func aVariantWritesItsOwnFiles() {
        let debug = "com.ipetinate.phantom.debug"

        #expect(PhantomBuild.fileName("phantom-tab-state.sh", forBundleID: debug)
            == "phantom-debug-tab-state.sh")
        #expect(PhantomBuild.fileName("phantom-integration.js", forBundleID: debug)
            == "phantom-debug-integration.js")
        #expect(PhantomBuild.fileName("phantom.ts", forBundleID: debug)
            == "phantom-debug.ts")
    }

    /// A name that is not this app's stays as it is. There is one — the
    /// pre-rename `ghostty-tab-state.sh` — and it belongs to the release
    /// build's history, not to a variant's.
    @Test func aNameThatIsNotOursIsLeftAlone() {
        #expect(
            PhantomBuild.fileName("ghostty-tab-state.sh", forBundleID: "com.ipetinate.phantom.debug")
                == "ghostty-tab-state.sh")
    }

    /// The two builds' names never collide, which is the whole property being
    /// bought here.
    @Test func theTwoBuildsNeverNameTheSameFile() {
        let release = PhantomBuild.fileName(
            "phantom-tab-state.sh", forBundleID: "com.ipetinate.phantom")
        let debug = PhantomBuild.fileName(
            "phantom-tab-state.sh", forBundleID: "com.ipetinate.phantom.debug")

        #expect(release != debug)
    }

    /// The configuration directory reads the same rule rather than a second
    /// copy of it.
    @Test func theConfigurationDirectoryAgreesWithTheFileNames() {
        #expect(GuiConfigStore.buildSuffix(forBundleID: "com.ipetinate.phantom") == nil)
        #expect(GuiConfigStore.buildSuffix(forBundleID: "com.ipetinate.phantom.debug")
            == PhantomBuild.variant(forBundleID: "com.ipetinate.phantom.debug"))
    }

    /// And so does the agent entry, so a reader debugging one of the three can
    /// reason about the other two.
    @MainActor
    @Test func theAgentEntryNameAgreesToo() {
        #expect(MCPServerCommand.name(forBundleID: "com.ipetinate.phantom.debug")
            == "phantom-debug")
    }
}
