import AppKit
import SwiftUI

/// The diff inside a review card.
///
/// The two-column pane the app already draws, and none of its own opinions:
/// the same scroll synchronisation, the same inline emphasis, the same signs
/// beside the numbers. A second renderer for the same job is a second place
/// for a diff to look wrong.
///
/// What it does not carry is the gap expansion. Clicking a gap in the diff
/// pane reloads the file with enough context to cover it, and inside a card
/// whose height is bounded that would replace a short diff with a whole file
/// and no way back — the card is the wrong place to hold that state. Opening
/// the file is one button away in the row above, and that is where the whole
/// file belongs.
struct GitReviewFileDiff: View {
    let document: GitDiffDocument
    let theme: CodeTheme
    let font: NSFont

    @ObservedObject var model: SplitPaneModel

    var body: some View {
        SplitPaneContainer(
            model: model,
            /// No direction toggle inside a card: the card's own height is
            /// bounded, so the choice a reader would make there is about a
            /// box they did not ask to arrange.
            showsDirectionToggle: false,
            accessoryTrailingInset: ThinScroller.trackWidth
        ) {
            GitDiffPane(
                rows: document.rows,
                side: .left,
                theme: theme,
                palette: GitDiffPalette.make(from: theme),
                font: font,
                scrollSync: model.scrollSync,
                syncSide: .first
            )
        } second: {
            GitDiffPane(
                rows: document.rows,
                side: .right,
                theme: theme,
                palette: GitDiffPalette.make(from: theme),
                font: font,
                scrollSync: model.scrollSync,
                syncSide: .second
            )
        } accessory: {
            EmptyView()
        }
        .onAppear { link() }
        .onDisappear { model.scrollSync.isEnabled = false }
    }

    /// Ties the two columns together.
    ///
    /// Both panes hold the same number of rows at the same height — that is
    /// what the filler rows in `GitDiffPane` are for — so equal offsets *are*
    /// line-for-line alignment, which is what `absolute` means and why nothing
    /// has to count lines.
    ///
    /// Both axes, because the two sides hold the same long lines: scrolling
    /// one sideways without the other puts different columns of the same line
    /// beside each other, which is worse than not scrolling at all.
    ///
    /// Switched off on the way out. The model belongs to the card and the card
    /// is inside a `LazyVStack`, so it is torn down and rebuilt as the reader
    /// scrolls past it — a link left on would be holding scroll views that no
    /// longer exist.
    private func link() {
        model.scrollSync.strategy = .absolute
        model.scrollSync.axes = .both
        model.scrollSync.isEnabled = true
    }
}
