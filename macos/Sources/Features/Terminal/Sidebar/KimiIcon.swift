import SwiftUI

/// The Kimi mark, tinted for the active theme.
///
/// **The one agent mark whose artwork is two-tone.** Kimi's own SVG fills its
/// two paths separately — a blue glyph and a near-black one — and a template
/// image reduces both to a single tint, so what ships here is the shape of the
/// mark rather than its colours.
///
/// That is a deliberate trade and not an oversight. Every mark in a sidebar
/// row, a group header or a toolbar reads as one icon among the SF Symbols
/// beside it, which is what `Tint.theme` exists for and what a two-colour mark
/// could not do. Antigravity is the precedent for the other direction: its
/// gradient did not survive flattening in a way anybody recognised, so it
/// carries a second coloured asset for the surfaces that want one. Kimi's
/// glyph is legible flat, so it does not — if that turns out to read wrong at
/// 12 points, the fix is that same second asset and not a change here.
struct KimiIcon: View {
    /// Which tint the mark takes. The same two cases every agent mark offers,
    /// so a row can ask for "the theme's icon colour" without knowing which
    /// agent it is drawing.
    enum Tint {
        /// The neutral secondary colour of the SF Symbols it sits beside.
        case theme

        /// The artwork's own blue, for surfaces that follow the system
        /// appearance rather than the terminal theme.
        case original
    }

    var size: CGFloat = 12
    var tint: Tint = .theme

    /// The blue of the artwork's larger path. The second, near-black path has
    /// no swatch of its own because a template cannot carry two.
    private static let kimiSwatch = Color(
        .sRGB,
        red: 0x01 / 255,
        green: 0x79 / 255,
        blue: 0xff / 255
    )

    private var color: Color {
        switch tint {
        case .original: return Self.kimiSwatch
        case .theme: return .secondary
        }
    }

    var body: some View {
        Image("KimiIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }
}
