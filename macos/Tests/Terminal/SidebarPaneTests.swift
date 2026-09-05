import Foundation
@testable import Ghostty
import Testing

/// Which panels the sidebar offers, and when it shows a tab bar at all.
///
/// The settings that drive this live in `UserDefaults` rather than
/// `GuiConfigStore` on purpose: an unknown key in `gui-settings` makes the
/// Ghostty core raise a "Configuration Errors" popup, so Phantom-only
/// preferences must never go there.
///
/// `.serialized` is load-bearing, not tidiness: these cases all write the
/// same two global `UserDefaults` keys, and run in parallel they set each
/// other's state out from under themselves.
@Suite(.serialized)
struct SidebarPaneTests {
    /// Wrapped in a saved/restored snapshot: these read the real user
    /// defaults, and a test must not leave the user's panels switched off
    /// behind it.
    private func withPanes(_ values: [SidebarPane: Bool], _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let keys = SidebarPane.allCases.compactMap(\.defaultsKey)
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                defaults.set(value, forKey: key)
            }
        }

        for pane in SidebarPane.allCases {
            guard let key = pane.defaultsKey else { continue }
            defaults.set(values[pane], forKey: key)
        }
        body()
    }

    private var everyExtraOff: [SidebarPane: Bool] {
        Dictionary(uniqueKeysWithValues: SidebarPane.allCases.filter(\.canBeHidden).map { ($0, false) })
    }

    /// Absent keys mean a fresh install, which gets everything.
    @Test func panesDefaultToEnabled() {
        withPanes([:]) {
            #expect(SidebarPane.enabled == SidebarPane.allCases)
            #expect(SidebarPane.showsTabBar)
        }
    }

    @Test func aDisabledPaneDropsOutOfTheTabOrder() {
        withPanes([.files: false, .git: true, .worktrees: true, .extensions: true]) {
            #expect(SidebarPane.enabled == [.terminals, .git, .worktrees, .extensions])
            #expect(SidebarPane.showsTabBar)
        }
    }

    @Test func extensionsIsOptOutLikeTheOtherExtras() {
        #expect(SidebarPane.extensions.canBeHidden)
        #expect(SidebarPane.extensions.defaultsKey == "SidebarShowExtensionsPane")
        #expect(SidebarPane.extensions.symbol == "puzzlepiece")
        #expect(SidebarPane.allCases.last == .extensions)
    }

    /// With both extras off there is nothing to switch between, so the bar
    /// hides and the sidebar goes back to being the plain terminal list it
    /// started as.
    @Test func turningEveryExtraOffHidesTheTabBar() {
        withPanes(everyExtraOff) {
            #expect(SidebarPane.enabled == [.terminals])
            #expect(!SidebarPane.showsTabBar)
        }
    }

    /// Terminals is the sidebar's reason to exist; the settings UI must
    /// never offer a switch for it.
    @Test func terminalsCannotBeHidden() {
        withPanes(everyExtraOff) {
            #expect(SidebarPane.terminals.isEnabled)
            #expect(!SidebarPane.terminals.canBeHidden)
            #expect(SidebarPane.terminals.defaultsKey == nil)
        }
    }

    @Test @MainActor func writingAKeyReachesTheSharedVisibility() {
        withPanes([:]) {
            let visibility = SidebarPaneVisibility.shared
            RunLoop.main.run(until: Date() + 0.05)
            #expect(visibility.isEnabled(.git))

            UserDefaults.standard.set(false, forKey: "SidebarShowGitPane")
            RunLoop.main.run(until: Date() + 0.05)
            #expect(!visibility.isEnabled(.git))
            #expect(visibility.enabled == SidebarPane.enabled)

            UserDefaults.standard.set(true, forKey: "SidebarShowGitPane")
            RunLoop.main.run(until: Date() + 0.05)
            #expect(visibility.isEnabled(.git))
        }
    }

    @Test func everyHideablePaneHasItsOwnDefaultsKey() {
        let keys = SidebarPane.allCases.compactMap(\.defaultsKey)
        #expect(keys.count == SidebarPane.allCases.filter(\.canBeHidden).count)
        #expect(Set(keys).count == keys.count)
    }

    /// Git ships its own artwork instead of an SF Symbol, so the tab bar
    /// has to go through `SidebarPaneIcon` rather than reading `symbol`
    /// directly — a nil here is the contract that keeps it honest.
    /// Git and worktrees ship their own artwork instead of an SF Symbol, so
    /// the tab bar has to go through `SidebarPaneIcon` rather than reading
    /// `symbol` directly — a nil here is the contract that keeps it honest.
    @Test func thePanesWithTheirOwnArtworkHaveNoSymbol() {
        #expect(SidebarPane.git.symbol == nil)
        #expect(SidebarPane.worktrees.symbol == nil)
        #expect(SidebarPane.terminals.symbol != nil)
        #expect(SidebarPane.files.symbol != nil)
        #expect(SidebarPane.extensions.symbol != nil)
    }
}
