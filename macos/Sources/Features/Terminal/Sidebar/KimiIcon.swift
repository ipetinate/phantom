import SwiftUI

/// The Kimi mark, tinted for the active theme.
///
/// **The asset here is not the file Kimi ships, and it cannot be.** Kimi's own
/// artwork is a dark rounded square with the letterform knocked *out* of it in
/// white, plus a blue accent. A template render flattens every opaque shape to
/// one tint, so the square wins and the mark disappears inside it — which is
/// exactly what shipping the file unchanged produced: a solid blue block in the
/// sidebar, the toolbar and the settings list.
///
/// There is also no monochrome glyph to extract, because the mark is defined by
/// negative space: the letterform is white and reads only against the square
/// behind it. So the asset is rebuilt — the background dropped, and the
/// letterform and its accent kept as positive shapes on transparency, which is
/// the one form that tints correctly. `fill-rule:evenodd` is carried over with
/// them, since the letterform's counters are holes rather than separate paths.
///
/// The colour is lost in the process, and that is the trade every mark in a
/// chrome row makes: it has to read as one icon among the SF Symbols beside it,
/// which is what `Tint.theme` exists for. Antigravity is the precedent for the
/// other direction — its gradient did not survive flattening in a way anybody
/// recognised, so it carries a second coloured asset. If this letterform turns
/// out to read wrong at 12 points, that second asset is the fix rather than a
/// change here.
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

    /// The blue of the artwork's accent. The letterform's own white is not a
    /// swatch anything can use: white on white is nothing, and it was never
    /// meant to be seen except against the square this asset drops.
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
