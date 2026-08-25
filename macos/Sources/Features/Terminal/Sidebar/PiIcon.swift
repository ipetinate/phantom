import SwiftUI

/// The Pi mark, tinted for the active theme.
///
/// The artwork is white, which is the reason it is drawn as a template and
/// never as it ships: a white mark laid on a light background is an invisible
/// mark. Tinting is what makes it work in both appearances, and it is why
/// `Tint.original` answers with a readable ink rather than with the file's own
/// fill — "the artwork's own colour" is the one value this mark cannot use.
struct PiIcon: View {
    /// Which tint the mark takes. The same two cases every agent mark offers,
    /// so a row can ask for "the theme's icon colour" without knowing which
    /// agent it is drawing.
    enum Tint {
        /// The neutral secondary colour of the SF Symbols it sits beside.
        case theme

        /// For surfaces that follow the system appearance rather than the
        /// terminal theme. `primary` rather than a swatch, so the mark
        /// inverts with light and dark instead of vanishing into one of them.
        case original
    }

    var size: CGFloat = 12
    var tint: Tint = .theme

    private var color: Color {
        switch tint {
        case .original: return .primary
        case .theme: return .secondary
        }
    }

    var body: some View {
        Image("PiIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }
}
