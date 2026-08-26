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
/// So this mark ships **twice**, and it is the only one that does. The other
/// three logos are one or two flat colours, which a silhouette plus a tint
/// describes completely. This one is a continuous gradient that changes in
/// two directions at once, and that is not a shape plus a colour — a
/// linear-gradient fill of the silhouette was tried first and read as a
/// different logo. Two assets here is not an exception for its own sake; it
/// is the logo not fitting in one.
///
/// Each answers for one case and cannot answer for the other. `.theme` wants
/// one more grey icon in a row of grey icons, which only a template can be.
/// `.original` wants the mark as Google draws it, which only the artwork can
/// be.
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

    var body: some View {
        switch tint {
        case .original:
            /// Drawn as it is, so `renderingMode` is left alone: asking for
            /// `.original` on an image that is already original is how a
            /// future reader learns nothing, and asking for `.template` here
            /// would throw away the only thing this asset has.
            Image("AntigravityIconColor")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)

        case .theme:
            Image("AntigravityIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }
}
