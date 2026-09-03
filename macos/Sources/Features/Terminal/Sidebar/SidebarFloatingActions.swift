import SwiftUI

extension View {
    /// Fades the row's own surface in under a cluster of floating buttons.
    ///
    /// A sidebar row's hover buttons are drawn *over* its content rather than
    /// beside it, so that a row reserves no width for buttons it is not
    /// drawing — see `SidebarTabRow.body`. That leaves a title, a branch chip
    /// or a group's description running underneath a column of icons, which
    /// neither of them survives without something in between.
    ///
    /// This is that something, and it is deliberately the row's own surface
    /// rather than a neutral slab: the reader should read the result as the
    /// text passing under the row's trailing edge, not as icons scribbled on
    /// top of it. The theme background goes down first because the sidebar
    /// paints none of its own — the window paints the theme colour behind it
    /// — so the row's translucent wash alone would let the covered text
    /// through.
    ///
    /// The leading padding is part of the deal: it is the width the fade needs,
    /// and it widens the cluster's box to the left without moving the buttons,
    /// which are held at the trailing edge by the layout that places them.
    func floatingActionScrim(_ surface: AnyShapeStyle, isRevealed: Bool) -> some View {
        modifier(FloatingActionScrim(surface: surface, isRevealed: isRevealed))
    }
}

private struct FloatingActionScrim: ViewModifier {
    let surface: AnyShapeStyle
    let isRevealed: Bool

    @ObservedObject private var palette: ThemePalette = .shared

    /// How far to the left of the first button the surface fades in.
    private static let fade: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(.leading, Self.fade)
            .background(scrim.opacity(isRevealed ? 1 : 0).allowsHitTesting(false))
    }

    /// The row's surface, opaque, with its leading `fade` points ramping up
    /// from nothing.
    ///
    /// Two slices rather than one masked view: a mask is sized to the view it
    /// masks, so a single rectangle widened by a negative padding would have
    /// its overhang masked away entirely. Slicing keeps every part of this
    /// inside the bounds it is drawn in.
    private var scrim: some View {
        HStack(spacing: 0) {
            filled
                .frame(width: Self.fade)
                .mask(
                    LinearGradient(
                        colors: [.black.opacity(0), .black],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            filled
        }
    }

    private var filled: some View {
        ZStack {
            Color(nsColor: palette.background ?? .windowBackgroundColor)
            Rectangle().fill(surface)
        }
    }
}
