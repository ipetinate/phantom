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
    @Test func everyAgentHasAMarkInTheCatalogue() throws {
        for agent in CodingAgent.allCases {
            let name = try #require(AgentBrandMark.asset(for: agent))
            #expect(NSImage(named: name) != nil, "\(agent) names \(name), which the bundle has not")
        }
    }

    /// Six agents, six marks. A duplicate would be the bug this replaced —
    /// one glyph standing for all of them — spelled differently.
    @Test func noTwoAgentsShareAMark() {
        let names = CodingAgent.allCases.compactMap { AgentBrandMark.asset(for: $0) }
        #expect(names.count == CodingAgent.allCases.count)
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
    @Test func sizingTheMenuIconLeavesTheCatalogueAlone() throws {
        let name = try #require(AgentBrandMark.asset(for: .claude))
        let before = NSImage(named: name)?.size
        _ = AgentBrandMark.menuIcon(for: .claude)
        #expect(NSImage(named: name)?.size == before)
        #expect(before?.width != AgentBrandMark.menuIconSide)
    }

    // MARK: A mark that is a file rather than an asset

    private let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="32" viewBox="0 0 24 32">\
        <rect width="24" height="32" fill="#336699"/></svg>
        """

    private func withSVGFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-mark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("aider.svg")
        try svg.write(to: file, atomically: true, encoding: .utf8)
        try body(file)
    }

    private func fileAgent(_ url: URL, keepsOriginalColours: Bool) -> AgentDescriptor {
        AgentDescriptor(
            id: "acme.aider",
            displayName: "Aider",
            launchCommand: "aider",
            resume: ResumeCommand(withSession: "aider --resume {session}", withoutSession: "aider"),
            installation: AgentInstallation(commands: [], documentation: nil),
            icon: .file(url),
            brandColour: .artwork,
            keepsOriginalColours: keepsOriginalColours,
            settingsKeyToken: "Aider",
            hooks: nil,
            mcp: nil,
            sessions: .none)
    }

    @Test func anSVGFileLoadsAsAMark() throws {
        try withSVGFile { file in
            let image = try #require(AgentBrandMark.image(for: .file(file)))
            #expect(image.size.width > 0)
            #expect(image.size.height > image.size.width)
        }
    }

    @Test func aFileMarkHasNoCatalogueName() throws {
        try withSVGFile { file in
            let descriptor = fileAgent(file, keepsOriginalColours: true)

            #expect(AgentBrandMark.asset(of: descriptor) == nil)
            #expect(AgentBrandMark.image(for: descriptor.icon) != nil)
        }
    }

    @Test func aFileMarkIsSizedAndTintedForAMenuLikeAnAsset() throws {
        try withSVGFile { file in
            let tinted = try #require(AgentBrandMark.menuIcon(
                for: fileAgent(file, keepsOriginalColours: false)))
            let coloured = try #require(AgentBrandMark.menuIcon(
                for: fileAgent(file, keepsOriginalColours: true)))

            #expect(tinted.size.height == AgentBrandMark.menuIconSide)
            #expect(tinted.size.width == AgentBrandMark.menuIconSide * 24 / 32)
            #expect(tinted.isTemplate)
            #expect(!coloured.isTemplate)
        }
    }

    @Test func aMissingFileIsNoMark() {
        let gone = URL(fileURLWithPath: "/nonexistent/phantom/aider.svg")

        #expect(AgentBrandMark.image(for: .file(gone)) == nil)
        #expect(AgentBrandMark.menuIcon(for: fileAgent(gone, keepsOriginalColours: false)) == nil)
    }

    @Test func aSymbolIsAMarkToo() {
        let image = AgentBrandMark.image(for: .symbol("sparkles"))
        #expect(image != nil)
    }
}
