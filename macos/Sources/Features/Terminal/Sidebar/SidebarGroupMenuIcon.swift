import AppKit
import SwiftUI

/// A group's own mark, as an image a menu row can hold, in the group's colour.
///
/// The submenu that moves a tab listed groups by name alone, which is the one
/// place in the app where a group is named without the mark and the colour the
/// reader chose for it — and those two are how a group is recognised in a
/// sidebar of twenty rows.
///
/// A separate path from `SidebarGroupIcon` because a menu item takes an
/// `NSImage` and not a view: AppKit flattens the row to a title and one image,
/// so a `Label` there can carry artwork but not a hierarchy. The four cases and
/// their fallback are `SidebarIconID.kind(of:)`'s, deliberately — a second
/// reading of an icon string is a second set of bugs.
enum SidebarGroupMenuIcon {
    /// The colour is applied to the image rather than left to the menu,
    /// which is why these are not templates: a template is tinted with the
    /// row's label colour and the group's colour would be the first thing
    /// lost. An emoji and an agent's mark carry their own colours already.
    static func image(for group: SidebarGroup) -> NSImage? {
        let side = AgentBrandMark.menuIconSide

        switch SidebarIconID.kind(of: group.icon) {
        case .agent(let agent):
            return AgentBrandMark.menuIcon(for: agent)

        case .emoji:
            return emoji(group.icon, side: side)

        case .empty, .unknownAgent:
            return symbol(Self.fallback, tint: group.accentColor, side: side)

        case .symbol:
            return symbol(group.icon, tint: group.accentColor, side: side)
        }
    }

    /// The same default `SidebarGroupIcon` draws, for the same two cases.
    private static let fallback = "folder"

    private static func symbol(_ name: String, tint: Color?, side: CGFloat) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        else { return nil }

        var configuration = NSImage.SymbolConfiguration(
            pointSize: side - 2, weight: .medium)

        /// A group with no colour of its own keeps the template treatment, so
        /// it follows the row's label like the symbols above and below it.
        /// Colour is the exception here, not the rule.
        guard let tint else {
            image.isTemplate = true
            return image.withSymbolConfiguration(configuration)
        }

        configuration = configuration.applying(
            NSImage.SymbolConfiguration(paletteColors: [NSColor(tint)]))
        let coloured = image.withSymbolConfiguration(configuration)
        coloured?.isTemplate = false
        return coloured
    }

    /// An emoji has no symbol to configure, so it is drawn.
    ///
    /// Centred in a square of the same side as every other mark in these
    /// menus, so a group with an emoji does not sit a pixel higher than the
    /// group above it.
    private static func emoji(_ text: String, side: CGFloat) -> NSImage? {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: side - 2)
        ]
        let string = text as NSString
        let measured = string.size(withAttributes: attributes)
        guard measured.width > 0, measured.height > 0 else { return nil }

        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            string.draw(
                at: NSPoint(
                    x: rect.midX - measured.width / 2,
                    y: rect.midY - measured.height / 2),
                withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }
}
