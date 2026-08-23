import SwiftUI

/// The Antigravity mark, tinted for the active theme.
///
/// Modelled on `ClaudeIcon` rather than on `CodexIcon`, and the source
/// artwork is why. Antigravity's logo is not a flat mark: it is that arch
/// silhouette used as a *mask* over eleven Gaussian-blurred colour blobs —
/// yellow at the top left, green down the left, red at the top right, blue
/// across the bottom. A template image carries one channel, alpha, so none of
/// that gradient can survive the trip. What does survive is the mask path
/// itself, which is a closed solid shape spanning the full width of its
/// 24×24 box (measured: x 0…24, y 1…23.109), so it flattens to a legible
/// glyph instead of the hairline the worktree artwork once shipped as.
///
/// `originalColors` is therefore not offered, because there are no original
/// colours to return to — only a choice of one of the four. The `.original`
/// tint picks the blue, which covers the whole lower half of the mark and is
/// the one Google leads the product's own branding with.
struct AntigravityIcon: View {
    /// Which tint the mark takes. The same two cases `ClaudeIcon` offers, for
    /// the same reason: a chrome row wants one more grey icon, and the
    /// Settings window follows the system appearance rather than the terminal
    /// theme and wants the brand colour.
    enum Tint {
        /// The neutral secondary colour the SF Symbol icons beside it use.
        case theme

        /// The one brand colour a single fill can carry.
        case original
    }

    var size: CGFloat = 12
    var tint: Tint = .theme

    /// The blue of the mark's largest blob, `#3186FF` in the source artwork.
    private static let skySwatch = Color(
        .sRGB,
        red: 0x31 / 255,
        green: 0x86 / 255,
        blue: 0xff / 255
    )

    private var color: Color {
        switch tint {
        case .original:
            return Self.skySwatch
        case .theme:
            return .secondary
        }
    }

    var body: some View {
        Image("AntigravityIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }
}
