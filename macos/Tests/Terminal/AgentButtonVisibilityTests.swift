@testable import Ghostty
import Testing

/// Which agent buttons each place draws, read through the pinned keys.
struct AgentButtonVisibilityTests {
    @Test func nothingStoredDrawsTheDefaults() {
        let shown = AgentButtonVisibility.read { _ in nil }

        for surface in AgentButtonSurface.allCases {
            #expect(shown[surface] == [.claude], Comment(rawValue: surface.rawValue))
        }
    }

    @Test func aStoredSwitchOverridesTheDefaultInItsPlaceOnly() {
        let stored: [String: Bool] = [
            "SidebarTabShowCodex": true,
            "SidebarShowClaude": false,
        ]
        let shown = AgentButtonVisibility.read { stored[$0] }

        #expect(shown[.tabRow] == [.claude, .codex])
        #expect(shown[.chrome] == [])
        #expect(shown[.groupHeader] == [.claude])
    }

    /// The order is the registry's, whatever order the switches were flipped in.
    @Test func theOrderIsTheRegistrysNotTheStores() {
        let stored: [String: Bool] = [
            "SidebarGroupShowPi": true,
            "SidebarGroupShowKimi": true,
            "SidebarGroupShowClaude": false,
        ]
        let shown = AgentButtonVisibility.read { stored[$0] }

        #expect(shown[.groupHeader] == [.kimi, .pi])
    }

    @Test func everyPlaceIsAnswered() {
        let shown = AgentButtonVisibility.read { _ in true }

        #expect(Set(shown.keys) == Set(AgentButtonSurface.allCases))
        for surface in AgentButtonSurface.allCases {
            #expect(shown[surface] == CodingAgent.allCases)
        }
    }
}
