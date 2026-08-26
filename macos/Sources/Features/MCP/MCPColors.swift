import AppKit
import Foundation

/// The colour vocabulary the tools share.
///
/// Its own file because two halves need it: a group takes a colour and so
/// does a terminal, and the names a model may use have to be the same list in
/// both — a colour accepted by one tool and refused by the other is a model
/// learning that Phantom is inconsistent.
@MainActor
enum MCPColors {
    /// The names a tool takes, which are the ones the reader's own menu
    /// offers. `none` is included deliberately: it is how a colour is
    /// *removed*, and leaving it out would make clearing one impossible to
    /// ask for.
    static var names: [String] {
        TerminalTabColor.allCases.map { $0.localizedName.lowercased() }
    }

    static func named(_ asked: String) -> TerminalTabColor? {
        let wanted = asked.trimmingCharacters(in: .whitespaces).lowercased()
        return TerminalTabColor.allCases.first { $0.localizedName.lowercased() == wanted }
    }

    static func refusal(_ asked: String) -> String {
        "Phantom has no colour called “\(asked)”. It offers "
        + names.joined(separator: ", ")
        + " — call list_theme_colors to see them with their hex values and pick "
        + "the nearest."
    }

    /// A colour as `#rrggbb`.
    ///
    /// Converted through sRGB first because a theme's colours arrive in
    /// whatever space the palette was parsed in, and `redComponent` traps on a
    /// colour that has no such component.
    static func hex(of colour: NSColor) -> String {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02x%02x%02x",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded()))
    }
}
