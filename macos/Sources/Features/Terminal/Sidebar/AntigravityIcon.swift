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
/// So the colours are put back on the *outside*: `.original` fills the
/// silhouette with a gradient of the artwork's own five colours instead of
/// one of them. `foregroundStyle` takes any `ShapeStyle`, and a template
/// image tinted with a gradient is filled by it — which needs no second
/// asset, stays resolution-independent, and reads as the multicolour mark it
/// is rather than as a blue arch.
///
/// It is an approximation and cannot be anything else: the original's colour
/// comes from eleven blobs behind a Gaussian blur, and neither the blur nor
/// the blobs survive an asset catalogue. What is faithful is the palette and
/// the order the colours run in along the arch, read off the source file.
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

    private static func swatch(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }

    /// The artwork's own five colours, in the order they run along the arch:
    /// blue up the left leg, red over the peak, yellow and green across the
    /// top, and the paler blue down the right. Taken from the source file
    /// rather than sampled from a screenshot, so a redraw of the logo can be
    /// diffed against it.
    private static let brand = LinearGradient(
        stops: [
            .init(color: swatch(0x3186ff), location: 0.00),
            .init(color: swatch(0xfc413d), location: 0.28),
            .init(color: swatch(0xffe432), location: 0.52),
            .init(color: swatch(0x00b95c), location: 0.74),
            .init(color: swatch(0x749bff), location: 1.00),
        ],
        startPoint: .leading,
        endPoint: .trailing)

    /// The blue of the mark's largest blob, kept for the one place a single
    /// colour is still the right answer: a gradient in a menu item's image is
    /// a smear at 14pt.
    static let skySwatch = swatch(0x3186ff)

    private var style: AnyShapeStyle {
        switch tint {
        case .original:
            return AnyShapeStyle(Self.brand)
        case .theme:
            return AnyShapeStyle(.secondary)
        }
    }

    var body: some View {
        Image("AntigravityIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(style)
    }
}
