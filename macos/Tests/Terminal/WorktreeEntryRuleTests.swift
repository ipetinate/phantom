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
        inRepository: Bool = true,
        idle: Bool = true,
        agent: Bool = false
    ) -> WorktreeEntryAction? {
        WorktreeEntryRule.action(
            at: entry,
            isEnabled: enabled,
            isInRepository: inRepository,
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

    /// Outside a repository there is nothing to switch between, and an icon
    /// that opens an empty list is worse than no icon.
    @Test func noPlaceOffersAnythingOutsideARepository() {
        for entry in WorktreeEntry.allCases {
            #expect(action(entry, inRepository: false) == nil, "\(entry.rawValue)")
        }
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
