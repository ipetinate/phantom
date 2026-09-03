import AppKit
import SwiftUI

/// The line an agent pointed at, and which agent pointed.
///
/// A value rather than anything drawable, because the rules worth being sure of
/// are rules about the value: which agent, which line, what an edit does to it,
/// what a second mark does to the first. All four are checkable without a
/// window, and `EditorDocument` invalidates the whole thing by assignment.
struct EditorAgentMark: Equatable {
    let agent: CodingAgent

    /// One-based, the way `reveal_line` counts and the way the gutter numbers.
    ///
    /// Read out of the revealed range at ``EditorCenter`` rather than passed
    /// beside it, so a mark and the caret it came with cannot name two
    /// different lines.
    let line: Int
}

/// An agent's mark in its own colours, at one size.
///
/// The mapping the Settings rows and `SidebarGroup` already make, in one place
/// now that the gutter needs it too. The reasoning is `SidebarGroup`'s: the
/// point of a brand mark is to be recognised at a glance, and four marks
/// flattened to the secondary label colour are four grey shapes that look
/// alike.
///
/// Claude's, Antigravity's and Kimi's artwork is template-only, so those carry
/// the one swatch their icon declares; Codex and OpenCode carry the colours in
/// their own assets, which for Codex is the whole blue-violet gradient rather
/// than a flat stop taken out of it.
///
/// Pi is the exception to the sentence above and cannot be helped: its artwork
/// is white, so there is no brand colour to be recognised by. It takes the
/// primary label colour, which at least inverts with the appearance instead of
/// disappearing into it.
struct AgentBrandMark: View {
    let agent: CodingAgent
    var size: CGFloat = 12

    var body: some View {
        switch agent {
        case .claude: ClaudeIcon(size: size, tint: .original)
        case .codex: CodexIcon(size: size, originalColors: true)
        case .opencode: OpenCodeIcon(size: size, originalColors: true)
        case .antigravity: AntigravityIcon(size: size, tint: .original)
        case .kimi: KimiIcon(size: size, tint: .original)
        case .pi: PiIcon(size: size, tint: .original)
        }
    }
}

extension AgentBrandMark {
    /// The asset behind the mark, for the places that need an image *name*
    /// rather than a view.
    ///
    /// A menu is the case this exists for. AppKit flattens a menu item to a
    /// title and one image, so a `Label` there can carry an asset name but not
    /// a view — which is why a group's six agent items all shared one SF
    /// Symbol, and why none of them said which agent it stood for.
    ///
    /// Written out rather than derived from the agent's display name or from
    /// its defaults key. `OpenCode` is one word in the catalogue and two in
    /// its name, and `AgentButtonDefaults` states plainly that its own
    /// spelling is a key and nothing else. Six lines that are each a fact
    /// beats one line that is a coincidence holding for five of them.
    ///
    /// The template variant, always: a menu tints its own images, and the
    /// coloured Antigravity artwork would come out inverted on a highlighted
    /// row while its neighbours followed the highlight.
    static func asset(for agent: CodingAgent) -> String {
        switch agent {
        case .claude: return "ClaudeIcon"
        case .codex: return "CodexIcon"
        case .opencode: return "OpenCodeIcon"
        case .antigravity: return "AntigravityIcon"
        case .kimi: return "KimiIcon"
        case .pi: return "PiIcon"
        }
    }
}

extension AgentBrandMark {
    /// The mark as an image a menu row can hold.
    ///
    /// A name is not enough, and that is the whole reason this exists beside
    /// `asset(for:)`. An SF Symbol scales itself to the menu's font; an asset
    /// has a size of its own and AppKit draws it at that size — so naming the
    /// artwork put a 1024-point Claude starburst in the menu, over the rows
    /// beneath it and most of the window. The size has to be said out loud.
    ///
    /// `isTemplate` is set here as well as in the catalogue, because a copy
    /// does not have to inherit it and a coloured mark on a highlighted row is
    /// the other half of the same problem.
    static func menuIcon(for agent: CodingAgent) -> NSImage? {
        guard let source = NSImage(named: asset(for: agent)) else { return nil }
        let icon = source.copy() as? NSImage ?? source
        icon.size = NSSize(width: menuIconSide, height: menuIconSide)
        icon.isTemplate = true
        return icon
    }

    /// What AppKit expects of a menu item's image, and what the SF Symbols in
    /// the same menus come out at.
    static let menuIconSide: CGFloat = 16
}

/// The agents' marks as bitmaps the gutter can draw, rendered once each.
///
/// ## Why they are rendered at all
///
/// The marks are SwiftUI views over asset images; the gutter is a single
/// `NSView` that draws every visible row by hand, because a label per line is a
/// hundred thousand subviews in a file this editor is expected to open. So the
/// view has to become an `NSImage`, and `ImageRenderer` is the only thing that
/// produces one. Snapshotting the hosting view is not an alternative: it was
/// tried for the tab drag and returned an empty image every time, because
/// SwiftUI draws through a layer tree `cacheDisplay` does not reach — see
/// `EditorTabDragSource`.
///
/// ## Why they are cached
///
/// `CodeGutterView.draw` runs on every scroll notification and walks every
/// visible row. A render on that path is a render per frame. So the pixels are
/// keyed by the three things that change them — which agent, how big, and the
/// screen's backing scale — and a scroll costs the view one dictionary lookup
/// it has already made before the frame starts. The draw itself only blits.
///
/// ## Why nil is a supported answer
///
/// `ImageRenderer` can fail, and an asset can go missing from a build. Both
/// come back as nil and travel all the way up as nil: a mark that cannot be
/// drawn is a mark not drawn. Nothing about `reveal_line` turns on it.
@MainActor
final class EditorAgentMarkImages {
    static let shared = EditorAgentMarkImages()

    private struct Key: Hashable {
        let agent: CodingAgent
        let size: CGFloat
        let scale: CGFloat
    }

    private var cache: [Key: NSImage] = [:]

    /// How a mark becomes pixels, injected so a test can count the renders.
    ///
    /// The thing worth asserting about this class is that it renders once per
    /// agent and size rather than once per frame, and asserting that means
    /// being able to see the renders. The real one also needs an asset
    /// catalogue and a screen, neither of which a value test should require.
    private let render: (CodingAgent, CGFloat, CGFloat) -> NSImage?

    init(
        render: @escaping (CodingAgent, CGFloat, CGFloat) -> NSImage?
            = EditorAgentMarkImages.rendered
    ) {
        self.render = render
    }

    /// The mark for an agent at a size, or nil when it could not be made.
    func image(for agent: CodingAgent, size: CGFloat) -> NSImage? {
        let key = Key(agent: agent, size: size, scale: Self.screenScale)
        if let cached = cache[key] { return cached }

        guard let image = render(key.agent, key.size, key.scale) else { return nil }
        cache[key] = image
        return image
    }

    /// The scale the marks are rendered at, which is the one the tab drag's
    /// preview already uses: a mark rendered at 1× carries a blurred copy of
    /// the artwork onto every Retina display, and every display this runs on
    /// is one.
    ///
    /// Part of the cache key rather than assumed, so a machine whose main
    /// screen changes gets a fresh render instead of the old one stretched.
    private static var screenScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    private static func rendered(
        agent: CodingAgent,
        size: CGFloat,
        scale: CGFloat
    ) -> NSImage? {
        let renderer = ImageRenderer(content: AgentBrandMark(agent: agent, size: size))
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }

        /// Turned off explicitly. A rendered mark already carries the agent's
        /// own colour, and a template is re-tinted by whatever fill colour the
        /// context happens to hold — in the gutter, the colour the last line
        /// number was drawn in. `ImageRenderer` does not set this, but the
        /// asset it drew from is a template and an `NSImage` that inherits the
        /// flag would arrive grey.
        image.isTemplate = false
        return image
    }
}
