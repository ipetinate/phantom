import Foundation
@testable import Ghostty
import Testing

/// Which places in the sidebar offer to switch worktrees, and what pressing
/// them means.
///
/// Worth its own suite for one reason: the button's job is to be *absent*
/// where pressing it would type `cd` into something that is not a shell.
/// Absence is what nobody notices being wrong.
struct WorktreeEntryRuleTests {
    private func action(
        _ entry: WorktreeEntry,
        enabled: Bool = true,
        reach: WorktreeEntryReach = .repository,
        idle: Bool = true,
        agent: Bool = false
    ) -> WorktreeEntryAction? {
        WorktreeEntryRule.action(
            at: entry,
            isEnabled: enabled,
            reach: reach,
            isIdle: idle,
            hasLiveAgent: agent)
    }

    // MARK: What each place means

    @Test func anIdleTerminalsOwnRowMovesThatTerminal() {
        #expect(action(.tabRow) == .migrate)
    }

    /// A header stands for several terminals and the chrome for all of them,
    /// so there is no single tab a switch could be about.
    @Test func theGroupHeaderAndTheChromeOpenSomethingNew() {
        #expect(action(.groupHeader) == .newTab)
        #expect(action(.chrome) == .newTab)
    }

    // MARK: When the row shows nothing

    /// The rule with teeth. `cd` typed at a build's stdin is input to the
    /// build; typed at an agent it is a message to the agent.
    @Test func aBusyTerminalOffersNothingOnItsRow() {
        #expect(action(.tabRow, idle: false) == nil)
    }

    @Test func aTerminalRunningAnAgentOffersNothingOnItsRow() {
        #expect(action(.tabRow, agent: true) == nil)
    }

    /// Not "falls back to a new tab". A button that means one thing while
    /// the terminal is quiet and another while it is busy is one nobody can
    /// predict, and both states look identical in a 240pt column.
    @Test func aBusyTerminalDoesNotSilentlyBecomeANewTabButton() {
        #expect(action(.tabRow, idle: false) != .newTab)
        #expect(action(.tabRow, agent: true) != .newTab)
    }

    /// The other two places are unaffected by what any one terminal is
    /// doing — they were never going to type into it.
    @Test func busynessDoesNotReachTheOtherTwoPlaces() {
        for entry in [WorktreeEntry.groupHeader, .chrome] {
            #expect(action(entry, idle: false) == .newTab)
            #expect(action(entry, agent: true) == .newTab)
        }
    }

    // MARK: Gates that apply everywhere

    /// With nothing to reach there is nothing to switch between, and an icon
    /// that opens an empty list is worse than no icon.
    @Test func noPlaceOffersAnythingWithNothingToReach() {
        for entry in WorktreeEntry.allCases {
            #expect(action(entry, reach: .nothing) == nil, "\(entry.rawValue)")
        }
    }

    // MARK: A folder that holds repositories without being one

    /// The bug this case exists for: a group header standing for
    /// `~/Projects/Aurora` counted as "not in a repository", so the button
    /// was handed the folder as a repository root and said it could not read
    /// its worktrees — over six repositories that read fine.
    @Test func aWorkspaceFolderOffersANewTerminalFromTheGroupHeaderAndTheChrome() {
        #expect(action(.groupHeader, reach: .workspace) == .newTab)
        #expect(action(.chrome, reach: .workspace) == .newTab)
    }

    /// Migrating needs a worktree to leave, and a folder that merely holds
    /// repositories is not one. The group header one row up is where the
    /// folder's repositories are offered.
    @Test func aWorkspaceFolderOffersNothingOnATerminalsOwnRow() {
        #expect(action(.tabRow, reach: .workspace) == nil)
    }

    /// A scan that has not answered has said nothing, and a button hidden on
    /// the strength of nothing is a button missing exactly when the folder is
    /// cold. It shows, and the popover says it is still looking.
    @Test func aFolderStillBeingScannedKeepsTheButton() {
        #expect(action(.groupHeader, reach: .searching) == .newTab)
        #expect(action(.chrome, reach: .searching) == .newTab)
    }

    @Test func aFolderStillBeingScannedOffersNothingOnATerminalsOwnRow() {
        #expect(action(.tabRow, reach: .searching) == nil)
    }

    // MARK: Resolving the reach

    /// The enclosing repository is asked about first, and that order is the
    /// point: a scan of a working directory inside a checkout could answer
    /// with a vendored repository two folders down.
    @Test func anEnclosingRepositoryWinsOverTheFolderBelowIt() {
        let reach = WorktreeEntryReach.resolve(
            repoRoot: "/repo",
            scanRoot: "/repo/src",
            discovered: ["/repo/src/vendor/other"])

        #expect(reach == .repository)
    }

    @Test func aFolderHoldingRepositoriesResolvesToAWorkspace() {
        let reach = WorktreeEntryReach.resolve(
            repoRoot: nil,
            scanRoot: "/Projects/Aurora",
            discovered: ["/Projects/Aurora/front", "/Projects/Aurora/back"])

        #expect(reach == .workspace)
    }

    /// One repository found by scanning is still a scan result. Which shape
    /// the chooser takes is `WorktreeScope`'s decision, made from the roots.
    @Test func oneRepositoryFoundByScanningIsStillAWorkspace() {
        let reach = WorktreeEntryReach.resolve(
            repoRoot: nil,
            scanRoot: "/Projects/Aurora",
            discovered: ["/Projects/Aurora/front"])

        #expect(reach == .workspace)
    }

    /// The distinction the whole type exists for. Nil is "still looking" and
    /// `[]` is "looked, found nothing" — collapsing them into one answer is
    /// what would flash the button on screen, or hide it while it is cold.
    @Test func nothingKnownYetIsNotTheSameAsNothingThere() {
        #expect(
            WorktreeEntryReach.resolve(
                repoRoot: nil, scanRoot: "/Projects/Aurora", discovered: nil) == .searching)
        #expect(
            WorktreeEntryReach.resolve(
                repoRoot: nil, scanRoot: "/Projects/Aurora", discovered: []) == .nothing)
    }

    /// A manual group names no repository and no folder, so there is nothing
    /// to scan and nothing to show.
    @Test func noFolderAtAllReachesNothing() {
        #expect(
            WorktreeEntryReach.resolve(repoRoot: nil, scanRoot: nil, discovered: nil) == .nothing)
        #expect(
            WorktreeEntryReach.resolve(repoRoot: "", scanRoot: "", discovered: nil) == .nothing)
    }

    @Test func theSettingHidesItsOwnPlaceAndOnlyThatPlace() {
        #expect(action(.tabRow, enabled: false) == nil)
        #expect(action(.groupHeader) == .newTab)
        #expect(action(.chrome) == .newTab)
    }

    // MARK: The settings keys

    /// Each place has its own key, and the three do not collide — a shared
    /// key would make one toggle silently move all three.
    @Test func everyPlaceHasItsOwnDefaultsKey() {
        let keys = WorktreeEntry.allCases.map(\.defaultsKey)

        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.contains("Worktree") })
    }

    /// The prefixes the sidebar already uses for each place, so the three
    /// toggles land beside their neighbours in Settings instead of forming a
    /// section of their own.
    @Test func theKeysFollowTheSidebarsExistingPrefixes() {
        #expect(WorktreeEntry.tabRow.defaultsKey == "SidebarTabShowWorktree")
        #expect(WorktreeEntry.groupHeader.defaultsKey == "SidebarGroupShowWorktree")
        #expect(WorktreeEntry.chrome.defaultsKey == "SidebarChromeShowWorktree")
    }
}
