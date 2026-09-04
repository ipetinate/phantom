import AppKit
import SwiftUI

/// A file's changes, drawn as two columns that scroll as one.
///
/// The load runs off the main actor and its five possible answers are all
/// drawn, because "no hunks" is not one outcome — a blank pane is how a
/// viewer tells a reader nothing and lets them decide it is broken.
struct GitDiffView<Accessory: View>: View {
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

    /// Enough context to reach the top and bottom of anything. Git clamps it
    /// to the file, so a number larger than any real file is the whole file
    /// without having to count its lines first.
    ///
    /// Computed rather than stored because this type is generic over its
    /// accessory, and a generic type cannot carry a static stored property.
    private static var wholeFileContext: Int { 1_000_000 }

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

    /// Whether the unchanged parts of the file are on screen too.
    ///
    /// Not a rendering choice: git decides what to print, so showing the rest
    /// means asking it again with enough context to cover any file.
    ///
    /// Bound rather than owned, because the control for it belongs in the
    /// host's own row of actions beside the presentation and split toggles —
    /// a second control floating next to that row reads as something else's.
    /// The host keeps the state; this view keeps the meaning.
    ///
    /// Declared after `reloadKey` so the call site reads in the order Swift
    /// requires of a memberwise initialiser.
    @Binding var showsWholeFile: Bool

    /// The host's own controls, handed to the split so they sit beside its
    /// direction toggle instead of on top of it. Both want the same corner,
    /// and the corner is the container's.
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        content
            .task(id: "\(reloadKey)\u{1}\(showsWholeFile)") { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch outcome {
        case .none:
            /// No spinner. The load is a `git diff` on one path, which
            /// returns faster than a spinner takes to stop looking like a
            /// glitch; a flash of empty background reads as "about to draw"
            /// where a flashing spinner reads as "something is wrong".
            ///
            /// Clear rather than the theme's background, for the reason
            /// spelled out on `GitDiffPane.body`: the layer behind this
            /// whole pane is already painting, and a colour of our own is a
            /// slab in a translucent window.
            Color.clear
                .overlay(alignment: .topTrailing) { accessory() }

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

        return SplitPaneContainer(
            model: model,
            /// The host's accessory carries the toggle inside its own box;
            /// a second copy here is the loose button this used to draw.
            showsDirectionToggle: false,
            accessoryTrailingInset: ThinScroller.trackWidth
        ) {
            GitDiffPane(
                document: document,
                side: .left,
                theme: theme,
                palette: palette,
                font: font,
                scrollSync: model.scrollSync,
                syncSide: .first,
                onExpandGap: showsWholeFile ? nil : { showsWholeFile = true }
            )
        } second: {
            GitDiffPane(
                document: document,
                side: .right,
                theme: theme,
                palette: palette,
                font: font,
                scrollSync: model.scrollSync,
                syncSide: .second,
                onExpandGap: showsWholeFile ? nil : { showsWholeFile = true }
            )
        } accessory: {
            accessory()
        }
        .onAppear { linkPanes() }
        /// Turned off on the way out because the model — and so the link —
        /// is shared with whatever else this document shows in a split. A
        /// raw markdown pane beside its rendered form has no row *n* to
        /// match, and leaving an absolute mapping switched on there would
        /// drag the preview to an offset that means nothing in it.
        .onDisappear { model.scrollSync.isEnabled = false }
    }

    /// The two panes hold the same row list, padded with fillers opposite
    /// each other's insertions and deletions, so row *n* is at the same y in
    /// both and equal offsets *are* line-for-line alignment — which is what
    /// `absolute` means and why no line counting is needed.
    ///
    /// Both axes, because the two sides hold the same long lines: scrolling
    /// one sideways without the other puts different columns of the same
    /// line beside each other, which is worse than not scrolling at all.
    private func linkPanes() {
        model.scrollSync.strategy = .absolute
        model.scrollSync.axes = .both
        model.scrollSync.isEnabled = true
    }

    /// What a diff with no rows actually means, which is never "nothing
    /// happened".
    private func emptyDiffReason(_ file: GitFileDiff) -> String {
        if file.isBinary { return "Binary file — git cannot describe the change." }
        if file.status == .renamed { return "Renamed from \(file.previousPath ?? "another path"), with no other change." }
        if file.oldMode != file.newMode { return "Only the file's permissions changed." }
        return "No line changes."
    }

    /// - Note: carries the accessory too. Without the split there is no
    ///   container to hand it to, and a reader who asked for a diff of a
    ///   file with no line changes would be left looking at one sentence
    ///   and no way back to the source.
    private func note(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { accessory() }
    }

    private func load() async {
        let change = change
        let side = side
        let root = root

        /// Off the main actor because it spawns `git` and waits on it. The
        /// loader is `nonisolated` for exactly this call.
        let context = showsWholeFile ? Self.wholeFileContext : GitDiffLoader.defaultContext
        let result = await Task.detached(priority: .userInitiated) {
            GitDiffLoader.load(change, side: side, in: root, context: context)
        }.value

        outcome = result
    }
}
