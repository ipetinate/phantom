import Foundation
@testable import Ghostty
import Testing

/// The Zig core actually linked into this build is the one in this checkout.
///
/// `xcodebuild` compiles only the Swift side. The core arrives as a
/// prebuilt `GhosttyKit.xcframework` that nothing regenerates and nothing
/// checks, so an app can be built, tested and shipped against a core from
/// another day and another branch — and nothing says so.
///
/// That happened: a stale core produced five windows on every launch, and
/// the search for a cause went through five eliminated hypotheses in the
/// Swift code before anyone thought to read the version the core reports.
/// The measurements were all careful and all against a binary that did not
/// contain the code being read.
///
/// When this fails, the fix is not here: run `zig build` and the core is
/// rebuilt from the current checkout.
struct CoreVersionFreshnessTests {
    /// `.version = "0.7.0-dev"` out of `build.zig.zon`.
    ///
    /// Read from the repository rather than from the bundle, because the
    /// bundle's version is written by the same build that could be stale —
    /// comparing those two would compare a thing with itself.
    private var declaredVersion: String? {
        let zon = URL(fileURLWithPath: #filePath)   // …/macos/Tests/App/<this>.swift
            .deletingLastPathComponent()             // …/macos/Tests/App
            .deletingLastPathComponent()             // …/macos/Tests
            .deletingLastPathComponent()             // …/macos
            .deletingLastPathComponent()             // repository root
            .appendingPathComponent("build.zig.zon")

        guard let contents = try? String(contentsOf: zon, encoding: .utf8) else { return nil }

        return contents
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.contains(".version") else { return nil }
                return line.split(separator: "\"").dropFirst().first.map(String.init)
            }
            .first
    }

    /// Guards the guard: a wrong path would let the check below pass by
    /// finding nothing to compare.
    @Test func theDeclaredVersionIsWhereWeThinkItIs() throws {
        let version = try #require(declaredVersion, "no .version in build.zig.zon")
        #expect(version.contains("."), "unexpected version format: \(version)")
    }

    /// The core reports `MAJOR.MINOR.PATCH-<branch>-+<sha>`; only the semver
    /// prefix is compared. The branch and commit legitimately differ from
    /// anything recorded in the repository, and pinning them would make this
    /// fail on every commit.
    @Test func theLinkedCoreWasBuiltFromThisCheckout() throws {
        let declared = try #require(declaredVersion)
        let reported = Ghostty.info.version

        let declaredSemver = declared.split(separator: "-").first.map(String.init) ?? declared

        #expect(
            reported.hasPrefix(declaredSemver),
            """
            The linked Zig core is not from this checkout.
              build.zig.zon: \(declared)
              core reports:  \(reported)
            Run `zig build` to rebuild GhosttyKit.xcframework. `xcodebuild`
            alone will not, and every runtime measurement until then describes
            the older core.
            """
        )
    }
}
