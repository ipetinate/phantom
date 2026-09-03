import AppKit
@testable import Ghostty
import Testing

/// The asset names the menus put beside an agent's name.
///
/// A menu item's image is looked up by name at draw time: a name that matches
/// nothing draws nothing, silently, and the row goes back to looking like the
/// five beside it. So the names are checked against the catalogue rather than
/// against a list written out twice.
@MainActor
struct AgentBrandAssetTests {
    @Test func everyAgentHasAMarkInTheCatalogue() {
        for agent in CodingAgent.allCases {
            let name = AgentBrandMark.asset(for: agent)
            #expect(NSImage(named: name) != nil, "\(agent) names \(name), which the bundle has not")
        }
    }

    /// Six agents, six marks. A duplicate would be the bug this replaced —
    /// one glyph standing for all of them — spelled differently.
    @Test func noTwoAgentsShareAMark() {
        let names = CodingAgent.allCases.map { AgentBrandMark.asset(for: $0) }
        #expect(Set(names).count == names.count)
    }

    /// The template variant, not the coloured one: a menu tints its images,
    /// and the coloured artwork inverts on a highlighted row.
    @Test func antigravityUsesTheTemplateAndNotTheColouredCopy() {
        #expect(AgentBrandMark.asset(for: .antigravity) == "AntigravityIcon")
    }

    /// The size has to be said out loud. An SF Symbol scales itself to the
    /// menu's font; an asset carries a size and AppKit draws it at that size,
    /// so naming the artwork put a 1024-point starburst over the menu and most
    /// of the window.
    @Test func aMenuIconIsSizedForAMenuRow() {
        for agent in CodingAgent.allCases {
            let icon = AgentBrandMark.menuIcon(for: agent)
            #expect(icon != nil, "\(agent) has no menu icon")
            #expect(icon?.size.width == AgentBrandMark.menuIconSide)
            #expect(icon?.size.height == AgentBrandMark.menuIconSide)
        }
    }

    /// Template, so the row's highlight tints it like the symbols beside it.
    @Test func aMenuIconIsATemplate() {
        for agent in CodingAgent.allCases {
            #expect(AgentBrandMark.menuIcon(for: agent)?.isTemplate == true)
        }
    }

    /// Sizing the copy must not resize the catalogue's own image, which every
    /// other drawing of the mark reads.
    @Test func sizingTheMenuIconLeavesTheCatalogueAlone() {
        let name = AgentBrandMark.asset(for: .claude)
        let before = NSImage(named: name)?.size
        _ = AgentBrandMark.menuIcon(for: .claude)
        #expect(NSImage(named: name)?.size == before)
        #expect(before?.width != AgentBrandMark.menuIconSide)
    }
}
