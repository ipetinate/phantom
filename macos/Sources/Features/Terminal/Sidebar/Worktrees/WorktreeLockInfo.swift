import SwiftUI

/// The ⓘ beside a locked worktree, and what it opens.
///
/// The row already says what the lock does. This answers the two questions
/// that come next and do not fit on a row: *why does this exist* and *how do
/// I get out of it*. Both have real answers, and neither is guessable — a
/// padlock in a sidebar looks like something the app did, when it is
/// entirely git's and entirely reversible.
///
/// It ends with the way out rather than describing it. Somebody who opened
/// this is looking for the button; sending them to a context menu they have
/// not found yet is one more step for no reason.
struct WorktreeLockInfo: View {
    let reason: String?

    /// Shown so the reader can run the command themselves — the pane is not
    /// the only way out, and seeing the path confirms which checkout this is
    /// about.
    let path: String

    let onUnlock: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared

    @State private var isShowing = false

    /// Git's own page for the command. The manual rather than a tutorial:
    /// it is the thing that stays correct, and `lock` is three paragraphs of
    /// it.
    private let documentation = URL(string: "https://git-scm.com/docs/git-worktree")

    var body: some View {
        SidebarIconButton(help: "About this lock") {
            isShowing = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Locked worktree")
                .font(palette.font(size: 12, weight: .semibold))

            /// What it is *for*, because that is what makes it stop looking
            /// like damage. A lock is a promise about a folder that is
            /// allowed to disappear.
            ///
            /// No backticks around `prune` here, tempting as it is: `Text`
            /// parses markdown only in a string literal, and this is built
            /// by concatenation to stay inside the line length — so the
            /// backticks would render as backticks.
            Text("Git locks checkouts that are allowed to vanish — on a removable "
                + "disk, or a network mount. While a worktree is locked, pruning "
                + "leaves it alone instead of deciding it is gone for good.")
                .font(palette.font(size: 11))
                .fixedSize(horizontal: false, vertical: true)

            if let reason = WorktreeLockNote.reason(reason) {
                /// Whoever locked it wrote this. Quoted rather than folded
                /// into a sentence of ours, because it is theirs.
                Text("Reason: \(reason)")
                    .font(palette.font(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            /// The part that is genuinely surprising, and the reason someone
            /// arrives here at all: Remove has already refused them once.
            /// Git wants a *second* force to override a lock, and this pane
            /// sends one — so from here, unlocking is the only way through.
            Text("Removing needs it unlocked first. The Remove in this panel "
                + "is refused even though it forces, because git asks for a "
                + "second force to override a lock.")
                .font(palette.font(size: 11))
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 8) {
                if let documentation {
                    Link("git worktree docs", destination: documentation)
                        .font(palette.font(size: 10.5))
                }

                Spacer(minLength: 0)

                Button("Unlock") {
                    isShowing = false
                    onUnlock()
                }
                .keyboardShortcut(.defaultAction)
            }

            /// Last, and small: the command is for the reader who would
            /// rather type it, and the path tells them which checkout the
            /// panel is talking about.
            ///
            /// Truncated at the head, not the middle. What identifies a
            /// worktree is its last path component — the middle ellipsis ate
            /// exactly that and left two directory names every worktree in
            /// the managed root shares.
            Text(verbatim: "git worktree unlock \(abbreviated)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.head)
        }
        .padding(12)
        .frame(width: 290)
    }

    private var abbreviated: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
