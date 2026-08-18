@testable import Ghostty
import Testing

/// How an agent's mark is written into the one string an icon has.
///
/// The string is shared with two older forms — an SF Symbol name and a single
/// emoji — and it is persisted, so the way these three tell each other apart
/// has to survive round trips and unfamiliar values. What follows is that
/// contract, not the drawing.
struct SidebarIconIDTests {
    @Test func anAgentSurvivesTheRoundTrip() {
        for agent in CodingAgent.allCases {
            #expect(SidebarIconID.agent(for: SidebarIconID.id(for: agent)) == agent)
        }
    }

    /// The older two forms must never be read as an agent. A symbol name with
    /// a colon does not exist and an emoji is one grapheme, so the prefix
    /// cannot collide — this pins that rather than trusting it.
    @Test func theOlderFormsAreNotAgents() {
        for icon in ["folder", "terminal", "wrench.and.screwdriver", "brain.head.profile", "🔥", "🤖", ""] {
            #expect(SidebarIconID.agent(for: icon) == nil, "\(icon) was read as an agent")
        }
    }

    /// A name from a newer build reads as no agent rather than as a wrong one,
    /// so the row falls back to its default symbol instead of drawing an empty
    /// box where an icon belongs.
    @Test func anUnknownAgentNameIsNotGuessedAt() {
        #expect(SidebarIconID.agent(for: "agent:aider") == nil)
        #expect(SidebarIconID.agent(for: "agent:") == nil)
        #expect(SidebarIconID.agent(for: "agent") == nil)
    }

    /// Case matters, because the stored form comes from the enum's raw value
    /// and nothing normalises it on the way back in.
    @Test func theStoredFormIsExactlyTheRawValue() {
        #expect(SidebarIconID.id(for: .claude) == "agent:claude")
        #expect(SidebarIconID.id(for: .codex) == "agent:codex")
        #expect(SidebarIconID.id(for: .opencode) == "agent:opencode")
        #expect(SidebarIconID.agent(for: "agent:Claude") == nil)
    }
}
