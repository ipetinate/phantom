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
            /// The longer side, not both: squaring a mark that is not square
            /// stretches it, and one of these is 240 by 300.
            #expect(max(icon?.size.width ?? 0, icon?.size.height ?? 0)
                == AgentBrandMark.menuIconSide)
        }
    }

    /// A square mark keeps its square.
    @Test func aSquareMarkFillsTheBox() {
        let size = AgentBrandMark.menuIconSize(for: NSSize(width: 512, height: 512))
        #expect(size.width == AgentBrandMark.menuIconSide)
        #expect(size.height == AgentBrandMark.menuIconSide)
    }

    /// And a tall one keeps its proportion. OpenCode's artwork is 240 by 300;
    /// squared, it drew a quarter too wide, which changes the shape of a logo.
    @Test func aTallMarkKeepsItsProportion() {
        let size = AgentBrandMark.menuIconSize(for: NSSize(width: 240, height: 300))
        #expect(size.height == AgentBrandMark.menuIconSide)
        #expect(size.width == AgentBrandMark.menuIconSide * 240 / 300)
        #expect(size.width < size.height)
    }

    /// A wide one too, so the rule is about the longer side and not about
    /// height.
    @Test func aWideMarkKeepsItsProportionAsWell() {
        let size = AgentBrandMark.menuIconSize(for: NSSize(width: 300, height: 240))
        #expect(size.width == AgentBrandMark.menuIconSide)
        #expect(size.height == AgentBrandMark.menuIconSide * 240 / 300)
    }

    /// A source that reports nothing must not divide by zero.
    @Test func anEmptySourceFallsBackToTheSquare() {
        let size = AgentBrandMark.menuIconSize(for: .zero)
        #expect(size.width == AgentBrandMark.menuIconSide)
        #expect(size.height == AgentBrandMark.menuIconSide)
    }

    /// Template, so the row's highlight tints it like the symbols beside it —
    /// for every mark that is a silhouette.
    @Test func aSilhouetteIsATemplate() {
        for agent in CodingAgent.allCases where !AgentBrandMark.keepsOriginalColours(for: agent) {
            #expect(AgentBrandMark.menuIcon(for: agent)?.isTemplate == true)
        }
    }

    /// And never for one that is not. A template is read through its alpha
    /// alone, and OpenCode's file paints the whole canvas and knocks the mark
    /// out of it in a second fill — so tinting it produced a solid block.
    @Test func aMarkThatIsNotASilhouetteKeepsItsColours() {
        #expect(AgentBrandMark.keepsOriginalColours(for: .opencode))
        #expect(AgentBrandMark.menuIcon(for: .opencode)?.isTemplate == false)
    }

    /// One exception, and it is named. Every other mark tints, and a second
    /// one appearing here should be a decision somebody made on purpose.
    @Test func opencodeIsTheOnlyException() {
        let exceptions = CodingAgent.allCases.filter(AgentBrandMark.keepsOriginalColours)
        #expect(exceptions == [.opencode])
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
