import SwiftUI

/// The worktree button, in whichever of the three places it appears.
///
/// One component rather than three, because what it does is decided by
/// `WorktreeEntryRule` and everything else — the popover, the create sheet,
/// the resolving of a repository to its family — is identical. Three copies
/// would be three places for the guard about typing into a busy shell to be
/// forgotten.
struct WorktreeEntryButton: View {
    let entry: WorktreeEntry

    /// This place's Settings toggle. Passed in rather than read here from
    /// `entry.defaultsKey`, because `@AppStorage` needs its key at property
    /// declaration and each caller already declares its own toggles that
    /// way.
    let isEnabled: Bool

    /// The repository the terminal is in, or nil. Only its presence is
    /// needed to decide whether to draw anything — resolving it to a family
    /// reads files, and that is deferred to the moment the popover opens.
    let repoRoot: String?

    /// The working directory the popover reasons from: which worktree is
    /// "here", and therefore which one is not offered.
    let currentPath: String?

    let isIdle: Bool
    let hasLiveAgent: Bool

    @ObservedObject var editorCenter: EditorCenter

    let terminalPwds: [String]

    let onMigrate: (GitWorktree, [WorktreeDocumentMigration.Outcome]) -> Void
    let onNewTerminal: (String) -> Void
    let onCreateGroup: (GitWorktree) -> Void
    let onViewFile: (String) -> Void

    /// Whether the row's actions are showing at all. The three places each
    /// have their own rule for that — hover, or a setting that pins them —
    /// and it is not this component's to decide.
    let isRevealed: Bool

    @State private var isShowingPopover = false
    @State private var isCreating = false

    private var action: WorktreeEntryAction? {
        WorktreeEntryRule.action(
            at: entry,
            isEnabled: isEnabled,
            isInRepository: !(repoRoot ?? "").isEmpty,
            isIdle: isIdle,
            hasLiveAgent: hasLiveAgent)
    }

    var body: some View {
        if let action {
            SidebarIconButton(help: help(action)) {
                isShowingPopover = true
            } label: {
                WorktreeIcon(size: 12)
                    .foregroundStyle(.secondary)
            }
            .opacity(isRevealed ? 1 : 0)
            .allowsHitTesting(isRevealed)
            .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
                popover(action)
            }
            .sheet(isPresented: $isCreating) {
                if let root = resolvedCommonRoot {
                    WorktreeCreator(
                        commonRoot: root,
                        onDone: { isCreating = false },
                        onOpenTerminal: onNewTerminal)
                }
            }
        }
    }

    /// The family this terminal's repository belongs to.
    ///
    /// A computed property read only from the presentation closures, never
    /// from `body`. Resolving reads a couple of small files, and `body` runs
    /// on every sidebar update for every row — so the cost is paid when
    /// something is actually opened.
    ///
    /// It used to be `@State`, written in the button's action alongside the
    /// flag that presents the popover. That is one ordering assumption too
    /// many: the popover came up before the write was visible to it and
    /// showed the "couldn't read" fallback over a repository that reads
    /// fine. Computing it where it is used has no order to get wrong.
    private var resolvedCommonRoot: String? {
        repoRoot.flatMap { GitCommonDir.resolve(from: $0) }
    }

    @ViewBuilder
    private func popover(_ action: WorktreeEntryAction) -> some View {
        if let root = resolvedCommonRoot {
            WorktreePopover(
                action: action,
                commonRoot: root,
                currentPath: currentPath,
                editorCenter: editorCenter,
                terminalPwds: terminalPwds,
                onMigrate: onMigrate,
                onNewTerminal: onNewTerminal,
                onNewWorktree: { isCreating = true },
                onCreateGroup: onCreateGroup,
                onViewFile: onViewFile,
                dismiss: { isShowingPopover = false })
        } else {
            /// A repository whose common directory could not be read — a
            /// `.git` file pointing nowhere, a folder that stopped being a
            /// checkout while the sidebar was looking at it. Said out loud
            /// rather than shown as an empty list.
            Text("Couldn't read this repository's worktrees.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(width: 220)
        }
    }

    private func help(_ action: WorktreeEntryAction) -> String {
        switch action {
        case .migrate: return "Switch This Terminal to Another Worktree"
        case .newTab: return "New Terminal in a Worktree"
        }
    }
}
