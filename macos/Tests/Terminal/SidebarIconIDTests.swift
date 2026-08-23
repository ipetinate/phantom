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

    /// The picker's emoji field trims what it holds to one character, so the
    /// question "is this an emoji" has to be asked about the string itself.
    ///
    /// It used to be asked backwards — anything absent from the picker's
    /// curated symbol list and not an agent — and the icon browser broke that
    /// the moment a symbol could come from outside the curated list: opening
    /// the sheet on `rectangle.3.group` put it in the emoji field, and one
    /// keystroke turned the tab's icon into `r`. These are the cases that
    /// must not read as emoji.
    @Test func onlyAnActualEmojiIsAnEmoji() {
        #expect(SidebarIconID.kind(of: "🔥") == .emoji)
        #expect(SidebarIconID.kind(of: "🤖") == .emoji)

        for icon in ["rectangle.3.group", "folder", "text.document", "50.square.fill", "f"] {
            #expect(SidebarIconID.kind(of: icon) == .symbol, "\(icon) read as \(SidebarIconID.kind(of: icon))")
        }
    }

    /// The five forms, each settled before the next test can see it.
    @Test func everyFormIsToldApart() {
        #expect(SidebarIconID.kind(of: "") == .empty)
        #expect(SidebarIconID.kind(of: "agent:claude") == .agent(.claude))
        #expect(SidebarIconID.kind(of: "agent:aider") == .unknownAgent)
        #expect(SidebarIconID.kind(of: "agent:") == .unknownAgent)
        #expect(SidebarIconID.kind(of: "agent") == .symbol)
    }

    /// A flag is one grapheme, so it is an emoji like any other — the count
    /// is of characters, not of scalars, and getting that backwards would put
    /// 🇧🇷 in the symbol bucket.
    ///
    /// Two of them are not. There is no fourth form to put that in, so it
    /// falls through to `symbol`, where it names nothing and draws nothing.
    /// Nothing produces it — the emoji field trims to one character, and
    /// `SidebarIconRecents.drawable` will not offer a name AppKit cannot
    /// resolve — so this pins the edge rather than asking for a fifth case.
    @Test func aFlagIsOneEmojiAndTwoAreNeither() {
        #expect(SidebarIconID.kind(of: "🇧🇷") == .emoji)
        #expect(SidebarIconID.kind(of: "🔥🔥") == .symbol)
    }
}
