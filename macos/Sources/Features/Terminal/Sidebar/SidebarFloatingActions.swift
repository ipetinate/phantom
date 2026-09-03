import SwiftUI

/// How wide the buttons floating over a row are, reported from the row's own
/// layout so its content can fade out exactly where they begin.
struct FloatingActionsWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Reports this view's width up the tree as the floating cluster's width.
    ///
    /// Measured rather than written down: the cluster is a worktree button and
    /// up to six agent marks, each behind its own setting, so its width is a
    /// number only the layout knows.
    func measuringFloatingActions() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: FloatingActionsWidthKey.self,
                    value: proxy.size.width
                )
            }
        )
    }

    /// Fades this view out under a cluster of buttons `width` points wide at
    /// its trailing edge.
    ///
    /// A sidebar row's hover buttons are drawn over its content rather than
    /// beside it, so that a row reserves no width for buttons it is not
    /// drawing — see `SidebarTabRow.body`. Something has to happen where the
    /// two meet, and this is a mask rather than a backdrop behind the buttons.
    ///
    /// A backdrop was the first attempt and it was wrong twice. It had to
    /// reproduce the row's own surface to be invisible, and it could not: the
    /// window paints the theme colour with the reader's opacity and blur, a
    /// group adds its own wash over that, and a flat repaint of the theme
    /// colour lands somewhere near but not on it. It was also only as tall as
    /// the buttons, because a row's vertical padding is applied outside the
    /// layout the buttons sit in — so it read as a dark plate floating inside
    /// the row.
    ///
    /// Fading the content has neither problem. Nothing new is painted, so
    /// there is no colour to get wrong and no rectangle to be the wrong
    /// height; the title simply stops before the icons start.
    func fadingUnderFloatingActions(width: CGFloat, isRevealed: Bool) -> some View {
        mask(
            HStack(spacing: 0) {
                Rectangle()

                if isRevealed, width > 0 {
                    LinearGradient(
                        colors: [.black, .black.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 22)

                    Color.clear.frame(width: width)
                }
            }
        )
    }
}
