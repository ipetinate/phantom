import SwiftUI

/// The worktree button, in whichever of the three places it appears.
///
/// One component rather than three, because what it does is decided by
/// `WorktreeEntryRule` and everything else — the popover, the create sheet,
/// the resolving of a folder to the families under it — is identical. Three
/// copies would be three places for the guard about typing into a busy shell
/// to be forgotten.
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

    /// A folder to look inside when `repoRoot` is nil: a workspace holding
    /// several checkouts side by side, or a project group's declared root.
    ///
    /// Nil where fanning out makes no sense — a terminal's own row, which
    /// offers to move that one terminal and needs one worktree to move it
    /// out of. The scan itself belongs to `GitCenter`, which caches it per
    /// folder and refuses folders too broad to walk.
    var scanRoot: String?

    /// The working directory the popover reasons from: which worktree is
    /// "here", and therefore which one is not offered.
    let currentPath: String?

    let isIdle: Bool
    let hasLiveAgent: Bool

    @ObservedObject var editorCenter: EditorCenter

    let terminalPwds: [String]

    let onMigrate: (GitWorktree, [WorktreeDocumentMigration.Outcome]) -> Void
    let onNewTerminal: (String) -> Void
    /// Nil hides the grouping item — see `WorktreePopover.onCreateGroup`.
    let onCreateGroup: ((GitWorktree) -> Void)?
    let onViewFile: (String) -> Void

    /// Whether the row's actions are showing at all. The three places each
    /// have their own rule for that — hover, or a setting that pins them —
    /// and it is not this component's to decide.
    let isRevealed: Bool

    @ObservedObject private var git: GitCenter = .shared

    @State private var isShowingPopover = false
    @State private var creating: CreateTarget?

    /// The family a create sheet is for.
    ///
    /// Identifiable so `.sheet(item:)` can present it. A flag plus a
    /// separately stored root is the ordering mistake this file already made
    /// once, in the note on `resolvedScope` below.
    private struct CreateTarget: Identifiable {
        let root: String
        var id: String { root }
    }

    private var reach: WorktreeEntryReach {
        WorktreeEntryReach.resolve(
            repoRoot: repoRoot,
            scanRoot: scanRoot,
            discovered: scanRoot.flatMap { git.workspaceRepos[$0] })
    }

    private var action: WorktreeEntryAction? {
        WorktreeEntryRule.action(
            at: entry,
            isEnabled: isEnabled,
            reach: reach,
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
            .sheet(item: $creating) { target in
                WorktreeCreator(
                    commonRoot: target.root,
                    onDone: { creating = nil },
                    onOpenTerminal: onNewTerminal)
            }
        }
    }

    /// The families this place can reach: the enclosing repository's, or one
    /// for each repository under the folder.
    ///
    /// A computed property read only from the presentation closures, never
    /// from `body`. Resolving reads a couple of small files per repository,
    /// and `body` runs on every sidebar update for every row — so the cost
    /// is paid when something is actually opened.
    ///
    /// It used to be `@State`, written in the button's action alongside the
    /// flag that presents the popover. That is one ordering assumption too
    /// many: the popover came up before the write was visible to it and
    /// showed the "couldn't read" fallback over a repository that reads
    /// fine. Computing it where it is used has no order to get wrong.
    ///
    /// Both derivations already exist and are reused rather than restated.
    /// `GitPanelScope` is what keeps an enclosing repository ahead of a scan
    /// of the folder below it, and `WorktreeScope` is what turns repository
    /// roots into families — including the part that is easy to get wrong,
    /// where a repository found by walking a workspace is itself a linked
    /// worktree.
    private var resolvedScope: WorktreeScope {
        WorktreeScope.resolve(
            GitPanelScope.resolve(
                repoRoot: repoRoot,
                pwd: scanRoot,
                discovered: scanRoot.flatMap { git.workspaceRepos[$0] }),
            commonRoot: { GitCommonDir.resolve(from: $0) })
    }

    @ViewBuilder
    private func popover(_ action: WorktreeEntryAction) -> some View {
        let scope = resolvedScope
        if scope.roots.isEmpty {
            unreadable
        } else {
            WorktreePopover(
                action: action,
                scope: scope,
                currentPath: currentPath,
                editorCenter: editorCenter,
                terminalPwds: terminalPwds,
                onMigrate: onMigrate,
                onNewTerminal: onNewTerminal,
                onNewWorktree: { root in creating = CreateTarget(root: root) },
                onCreateGroup: onCreateGroup,
                onViewFile: onViewFile,
                dismiss: { isShowingPopover = false })
        }
    }

    /// Nothing to list, for one of two reasons, and they need different
    /// sentences. A repository whose common directory could not be read — a
    /// `.git` file pointing nowhere, a folder that stopped being a checkout
    /// while the sidebar was looking at it — is a failure. A folder whose
    /// scan has not answered yet is not, and saying "couldn't read" over it
    /// was the whole of the bug this state exists to end.
    ///
    /// The scan is asked for from here as well as from the sidebar's own
    /// prefetch. Forced, because a cached empty answer is exactly what a
    /// reader who opened this is disagreeing with.
    private var unreadable: some View {
        VStack(spacing: 6) {
            if reach == .searching {
                ProgressView().controlSize(.small)
                Text("Looking for repositories…")
            } else {
                Text("Couldn't read this repository's worktrees.")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(width: 220)
        .onAppear {
            guard let scanRoot, !scanRoot.isEmpty else { return }
            git.requestWorkspaceRepos(root: scanRoot, force: true)
        }
    }

    private func help(_ action: WorktreeEntryAction) -> String {
        switch action {
        case .migrate: return "Switch This Terminal to Another Worktree"
        case .newTab: return "New Terminal in a Worktree"
        }
    }
}
