import Foundation
import SwiftUI
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
        let keys = SidebarPane.builtIns.compactMap(\.defaultsKey)
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                defaults.set(value, forKey: key)
            }
        }

        for pane in SidebarPane.builtIns {
            guard let key = pane.defaultsKey else { continue }
            defaults.set(values[pane], forKey: key)
        }
        body()
    }

    private var everyExtraOff: [SidebarPane: Bool] {
        Dictionary(uniqueKeysWithValues: SidebarPane.builtIns.filter(\.canBeHidden).map { ($0, false) })
    }

    /// Absent keys mean a fresh install, which gets everything.
    @Test func panesDefaultToEnabled() {
        withPanes([:]) {
            #expect(SidebarPane.enabled == SidebarPane.builtIns)
        }
    }

    @Test func aDisabledPaneDropsOutOfTheTabOrder() {
        withPanes([.files: false, .git: true, .worktrees: true, .extensions: true]) {
            #expect(SidebarPane.enabled == [.terminals, .git, .worktrees, .extensions, .orchestrator])
        }
    }

    @Test func extensionsIsOptOutLikeTheOtherExtras() {
        #expect(SidebarPane.extensions.canBeHidden)
        #expect(SidebarPane.extensions.defaultsKey == "SidebarShowExtensionsPane")
        #expect(SidebarPane.extensions.symbol == "square.grid.2x2")
        #expect(SidebarPane.builtIns.dropLast().last == .extensions)
        #expect(SidebarPane.builtIns.last == .orchestrator)
        #expect(SidebarPane.orchestrator.canBeHidden)
        #expect(SidebarPane.orchestrator.defaultsKey == "SidebarShowOrchestratorPane")
    }

    /// With both extras off there is nothing to switch between, so the bar
    /// hides and the sidebar goes back to being the plain terminal list it
    /// started as.
    @Test @MainActor func turningEveryExtraOffHidesTheTabBar() {
        withPanes(everyExtraOff) {
            let visibility = SidebarPaneVisibility.shared
            RunLoop.main.run(until: Date() + 0.05)
            #expect(visibility.enabled == [.terminals])
            #expect(!visibility.showsTabBar)
        }

        withPanes([:]) {
            let visibility = SidebarPaneVisibility.shared
            RunLoop.main.run(until: Date() + 0.05)
            #expect(visibility.showsTabBar)
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
            #expect(visibility.enabled.filter { $0.contributedViewID == nil } == SidebarPane.enabled)

            UserDefaults.standard.set(true, forKey: "SidebarShowGitPane")
            RunLoop.main.run(until: Date() + 0.05)
            #expect(visibility.isEnabled(.git))
        }
    }

    @Test @MainActor func theVisibilityBindingWritesAndReadsThePaneKey() {
        withPanes([:]) {
            let visibility = SidebarPaneVisibility.shared
            for pane in SidebarPane.builtIns.filter(\.canBeHidden) {
                guard let key = pane.defaultsKey else { continue }
                let binding = visibility.binding(for: pane)
                #expect(binding.wrappedValue)

                binding.wrappedValue = false
                #expect(UserDefaults.standard.object(forKey: key) as? Bool == false)
                #expect(!binding.wrappedValue)

                binding.wrappedValue = true
                #expect(UserDefaults.standard.object(forKey: key) as? Bool == true)
                #expect(binding.wrappedValue)
            }
        }
    }

    /// A contributed panel is switched by the same binding, on a key of its
    /// own, so the reader can close somebody else's window without
    /// uninstalling the extension.
    @Test @MainActor func aContributedPaneIsSwitchedByItsOwnKey() {
        let pane = SidebarPane.view("ipetinate.bruno/http")
        let key = "SidebarShowExtensionView.ipetinate.bruno/http"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        #expect(pane.defaultsKey == key)
        let binding = SidebarPaneVisibility.shared.binding(for: pane)
        #expect(binding.wrappedValue)

        binding.wrappedValue = false
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == false)
        #expect(!pane.isEnabled)
    }

    @Test @MainActor func theTerminalsBindingHasNoKeyToWrite() {
        withPanes(everyExtraOff) {
            let binding = SidebarPaneVisibility.shared.binding(for: .terminals)
            #expect(binding.wrappedValue)
            binding.wrappedValue = false
            #expect(binding.wrappedValue)
        }
    }

    @Test func theSwitcherMenuOffersBothPlacementsThenEveryPane() {
        #expect(SidebarPaneSwitcherMenu.entries(contributing: []) == [
            .placement(.top),
            .placement(.side),
            .separator,
            .pane(SidebarPaneItem(.terminals), canToggle: false),
            .pane(SidebarPaneItem(.files), canToggle: true),
            .pane(SidebarPaneItem(.git), canToggle: true),
            .pane(SidebarPaneItem(.worktrees), canToggle: true),
            .pane(SidebarPaneItem(.extensions), canToggle: true),
            .pane(SidebarPaneItem(.orchestrator), canToggle: true),
        ])
    }

    /// A contributed panel lands after a separator of its own, so the
    /// built-ins the reader knows stay where they were.
    @Test func aContributedPaneLandsAfterTheBuiltIns() {
        let item = SidebarPaneItem(
            ExtensionViewDescriptor(
                extensionID: "ipetinate.bruno", extensionName: "Bruno",
                root: URL(fileURLWithPath: "/tmp/bruno"),
                contribution: ExtensionViewContribution(
                    viewID: "http", title: "HTTP",
                    icon: URL(fileURLWithPath: "/tmp/bruno/views/http.png"),
                    entry: URL(fileURLWithPath: "/tmp/bruno/views/http.js"),
                    style: nil, surface: .sidebar, filenamePatterns: [], priority: .option,
                    placements: [.sidebar], permissions: [])))

        let entries = SidebarPaneSwitcherMenu.entries(contributing: [item])
        #expect(entries.suffix(2) == [.separator, .pane(item, canToggle: true)])
        #expect(entries.dropLast(2) == SidebarPaneSwitcherMenu.entries(contributing: []))
    }

    @Test func theSwitcherMenuNamesEveryPaneOnce() {
        let panes = SidebarPaneSwitcherMenu.entries(contributing: []).compactMap { entry -> SidebarPane? in
            guard case .pane(let item, _) = entry else { return nil }
            return item.pane
        }
        #expect(panes == SidebarPane.builtIns)
    }

    @Test func onlyTerminalsIsUntoggleableInTheSwitcherMenu() {
        let locked = SidebarPaneSwitcherMenu.entries(contributing: []).compactMap { entry -> SidebarPane? in
            guard case .pane(let item, let canToggle) = entry, !canToggle else { return nil }
            return item.pane
        }
        #expect(locked == [.terminals])
    }

    @Test func everySwitcherMenuEntryHasItsOwnIdentity() {
        let ids = SidebarPaneSwitcherMenu.entries(contributing: []).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyHideablePaneHasItsOwnDefaultsKey() {
        let keys = SidebarPane.builtIns.compactMap(\.defaultsKey)
        #expect(keys.count == SidebarPane.builtIns.filter(\.canBeHidden).count)
        #expect(Set(keys).count == keys.count)
    }

    /// Git and worktrees ship their own artwork instead of an SF Symbol, so
    /// the tab bar has to go through `SidebarPaneIcon` rather than reading
    /// `symbol` directly — a nil here is the contract that keeps it honest.
    /// A contributed panel is the same case, and the reason the contract
    /// matters: its artwork is a file, and a symbol name a manifest chose
    /// could be one this macOS does not resolve.
    @Test func thePanesWithTheirOwnArtworkHaveNoSymbol() {
        #expect(SidebarPane.git.symbol == nil)
        #expect(SidebarPane.worktrees.symbol == nil)
        #expect(SidebarPane.view("ipetinate.bruno/http").symbol == nil)
        #expect(SidebarPane.terminals.symbol != nil)
        #expect(SidebarPane.files.symbol != nil)
        #expect(SidebarPane.extensions.symbol != nil)
    }

    /// A contributed panel's raw value can never spell a built-in's, because
    /// the prefix holds a colon and neither an extension id nor a view id
    /// may contain one.
    @Test func aContributedPaneCannotSpellABuiltIn() {
        for pane in SidebarPane.builtIns {
            #expect(!pane.rawValue.hasPrefix(SidebarPane.viewPrefix))
            #expect(SidebarPane.view(pane.rawValue) != pane)
        }
        #expect(SidebarPane(rawValue: "view:").contributedViewID == nil)
        #expect(LanguageManifest.validID("a:b") == nil)
        #expect(LanguageContribution.validLanguageID("a:b") == nil)
    }

    /// The switcher is one list drawn in one of two places, so a manifest's
    /// `placements` is checked against where the reader put the bar.
    @Test func aPlacementNamesTheContributionItAccepts() {
        #expect(SidebarTabBarPlacement.top.contribution == .topBar)
        #expect(SidebarTabBarPlacement.side.contribution == .sidebar)
    }
}
