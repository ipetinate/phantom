import Foundation
@testable import Ghostty
import Testing

/// What the Languages pane offers for a row, which is decided by the row's
/// state and nothing else.
///
/// The pane used to show two buttons side by side — a dependency button and
/// Uninstall — which is mechanism rather than state. The reader looking at a
/// row asks one question, "does this need me", and two controls made them work
/// the answer out. In a narrow pane the pair truncated to "Instal…" and
/// "Unin…", putting a destructive action one mis-click from a routine one.
///
/// The rules below are what replaced it. They are asserted here rather than in
/// the view because they are a decision, and a decision that lives only in a
/// `body` regresses without anybody noticing.
struct LSPServerRowStateTests {
    private let plan = LSPServerDependencyPlan(
        packages: [
            LSPServerDependency(
                package: "@vue/language-server",
                pin: "3.3.10",
                purpose: "Serves the template.",
                installer: .npmGlobal,
                presence: .binary("vue-language-server")),
            LSPServerDependency(
                package: "@vue/typescript-plugin",
                pin: "3.3.10",
                purpose: "Registers Vue with tsserver.",
                installer: .npmGlobal,
                presence: .globalPackage),
        ],
        projectNote: nil)

    private func statuses(
        binaries: Set<String>,
        versions: [String: String]
    ) -> [String: LSPDependencyStatus] {
        LSPDependencyCatalog.statuses(
            for: plan,
            installedCommands: binaries,
            globalVersions: versions)
    }

    private func outstanding(_ statuses: [String: LSPDependencyStatus]) -> Int {
        plan.packages.filter { (statuses[$0.id] ?? .unknown).needsInstall }.count
    }

    // MARK: Nothing installed

    @Test func aBareMachineNeedsEverything() {
        let found = statuses(binaries: [], versions: [:])

        #expect(outstanding(found) == plan.packages.count)
    }

    // MARK: Everything satisfied — the state that had no control of its own

    @Test func aFullySatisfiedRowNeedsNothing() {
        let found = statuses(
            binaries: ["vue-language-server"],
            versions: [
                "@vue/language-server": "3.3.10",
                "@vue/typescript-plugin": "3.3.10",
            ])

        #expect(outstanding(found) == 0)
        #expect(found["@vue/language-server"] == .present)
        #expect(found["@vue/typescript-plugin"] == .present)
    }

    // MARK: The reported case

    /// The pair installed but behind the pin. This is the row that used to say
    /// "Dependencies" — a noun where the reader needed a verb, and one that
    /// said nothing about whether anything was wrong.
    @Test func anOutdatedPairAsksToBeUpdated() {
        let found = statuses(
            binaries: ["vue-language-server"],
            versions: [
                "@vue/language-server": "2.2.12",
                "@vue/typescript-plugin": "2.2.12",
            ])

        #expect(outstanding(found) == 2)
        #expect(found["@vue/language-server"] == .outdated(installed: "2.2.12"))
    }

    @Test func onePackageBehindIsNotTheWholeRow() {
        let found = statuses(
            binaries: ["vue-language-server"],
            versions: [
                "@vue/language-server": "3.3.10",
                "@vue/typescript-plugin": "2.2.12",
            ])

        #expect(outstanding(found) == 1, "the row offers to update one of two, not to install")
    }

    // MARK: Unknown is not missing

    /// The distinction the probe fix restored. A status nobody has measured
    /// must not count as work to do, or a pane that could not reach npm offers
    /// to reinstall a machine that is already correct.
    @Test func anUnmeasuredPackageIsNotOutstanding() {
        #expect(!LSPDependencyStatus.unknown.needsInstall)
        #expect(LSPDependencyStatus.missing.needsInstall)
        #expect(LSPDependencyStatus.outdated(installed: "1.0.0").needsInstall)
        #expect(!LSPDependencyStatus.present.needsInstall)
    }

    /// A binary installed from somewhere npm does not own — a version manager,
    /// Homebrew, a project's own bin — is there. Calling it outdated because
    /// this app could not read a version would offer to reinstall something
    /// that works.
    @Test func aBinaryWithNoReadableVersionIsPresent() {
        let found = statuses(binaries: ["vue-language-server"], versions: [:])

        #expect(found["@vue/language-server"] == .present)
        #expect(found["@vue/typescript-plugin"] == .missing, "a package with no binary has nothing else to go on")
    }
}
