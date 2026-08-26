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
    }
}
