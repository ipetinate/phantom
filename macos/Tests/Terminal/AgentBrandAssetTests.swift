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
}
