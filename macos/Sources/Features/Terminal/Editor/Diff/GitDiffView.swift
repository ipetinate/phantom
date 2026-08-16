import AppKit
import SwiftUI

/// A file's changes, drawn as two columns that scroll as one.
///
/// The load runs off the main actor and its five possible answers are all
/// drawn, because "no hunks" is not one outcome — a blank pane is how a
/// viewer tells a reader nothing and lets them decide it is broken.
struct GitDiffView: View {
    let path: String
    let root: String
    let change: GitFileChange
    let side: GitDiffSide
    let theme: CodeTheme
    let font: NSFont

    /// Shared with whatever else is in the split, so the two panes here and
    /// the source beside them are one arrangement rather than three.
    @ObservedObject var model: SplitPaneModel

    @State private var outcome: GitDiffOutcome?

    /// Changes exactly when the diff on screen has gone stale.
    ///
    /// Deliberately **not** the document's edit revision: that moves on
    /// every keystroke, and this spawns a `git` process. Keyed on the
    /// staged/worktree letters and on whether the buffer is dirty, the diff
    /// reloads when the file is saved, staged or unstaged — and holds still
    /// while somebody is typing into it. The cost is that the diff of an
    /// unsaved buffer describes the file on disk, which is what `git diff`
    /// means anyway.
    let reloadKey: String

    var body: some View {
        content
            .task(id: reloadKey) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch outcome {
        case .none:
            /// No spinner. The load is a `git diff` on one path, which
            /// returns faster than a spinner takes to stop looking like a
            /// glitch; a flash of empty background reads as "about to draw"
            /// where a flashing spinner reads as "something is wrong".
            Color(nsColor: theme.background)

        case .diff(let document):
            if document.rows.isEmpty {
                note(emptyDiffReason(document.file))
            } else {
                panes(document)
            }

        case .unchanged:
            note("No changes on this side.")

        case .conflicted:
            note("This file has conflicts. Resolve them to see a diff.")

        case .tooLarge(let bytes):
            note("This diff is \(bytes / 1_048_576) MB — too large to draw.")

        case .failed(let failure):
            note(failure.summary ?? failure.title)
        }
    }

    private func panes(_ document: GitDiffDocument) -> some View {
        let palette = GitDiffPalette.make(from: theme)

        return SplitPaneContainer(model: model) {
            GitDiffPane(
                rows: document.rows,
                side: .left,
                theme: theme,
                palette: palette,
                font: font
            )
            .synchronizedScroll(model.scrollSync, as: .first)
        } second: {
            GitDiffPane(
                rows: document.rows,
                side: .right,
                theme: theme,
                palette: palette,
                font: font
            )
            .synchronizedScroll(model.scrollSync, as: .second)
        }
    }

    /// What a diff with no rows actually means, which is never "nothing
    /// happened".
    private func emptyDiffReason(_ file: GitFileDiff) -> String {
        if file.isBinary { return "Binary file — git cannot describe the change." }
        if file.status == .renamed { return "Renamed from \(file.previousPath ?? "another path"), with no other change." }
        if file.oldMode != file.newMode { return "Only the file's permissions changed." }
        return "No line changes."
    }

    private func note(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.background))
    }

    private func load() async {
        let change = change
        let side = side
        let root = root

        /// Off the main actor because it spawns `git` and waits on it. The
        /// loader is `nonisolated` for exactly this call.
        let result = await Task.detached(priority: .userInitiated) {
            GitDiffLoader.load(change, side: side, in: root)
        }.value

        outcome = result
    }
}
