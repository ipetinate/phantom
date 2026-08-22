import Combine
import SwiftUI

/// Asks the worktree panel to reload, from the titlebar's refresh button.
/// Same shape as `GitPanelRefresh`, for the same reason: the button lives in
/// the chrome and the panel lives in the sidebar, and a token is the smallest
/// thing that can cross that gap.
@MainActor
final class WorktreePanelRefresh: ObservableObject {
    static let shared = WorktreePanelRefresh()
    @Published private(set) var token = 0
    func request() { token += 1 }
}

/// The sidebar's worktree panel: every place a repository is checked out, who
/// is working there, and what is finished with.
///
/// Follows the selected terminal the way Files and Git do — same triple of
/// subscriptions, same reason for each — and takes one of the two shapes
/// `WorktreeScope` decides between. A tab inside a repository gets that
/// repository's whole family, resolved through `GitCommonDir` so the panel
/// describes the family and not the one member the tab happens to sit in. A
/// tab in a folder that merely *contains* repositories gets one collapsible
/// section each, because a workspace like `~/Projects` is a real place to
/// work from and answering "no git repository here or below" while sitting on
/// top of five of them was never useful.
///
/// The per-repository half lives in `WorktreeFamilyView`, which owns its own
/// dialogs. That is what lets several of them coexist without this view
/// tracking which repository each half-answered alert belonged to.
struct WorktreePanelView: View {
    @ObservedObject var tabManager: SidebarTabManager

    /// Passed through to the sections, for one sentence: removing a worktree
    /// discards any unsaved edits in the files open from it, and the editor
    /// is the only thing that knows there are any.
    @ObservedObject var editorCenter: EditorCenter

    let onNewTerminal: (String) -> Void
    let onNewAgentTab: (String, CodingAgent) -> Void

    @ObservedObject private var center: WorktreeCenter = .shared
    @ObservedObject private var git: GitCenter = .shared
    @ObservedObject private var refresh: WorktreePanelRefresh = .shared
    @ObservedObject private var palette: ThemePalette = .shared

    /// The three facts the scope is derived from, kept together so the
    /// derivation can be skipped when none of them moved.
    ///
    /// It is not free: resolving a repository to its family reads files, and
    /// a workspace of twenty resolves twenty of them. The subscription below
    /// fires on every change to every tab — a title, a working directory —
    /// which is far more often than any of these three actually change.
    private struct ScopeInputs: Equatable {
        var repoRoot: String?
        var pwd: String?
        var discovered: [String]?
    }

    @State private var inputs = ScopeInputs()
    @State private var scope: WorktreeScope = .none

    /// Sections the reader has opened. Absence means collapsed: unlike the
    /// Git panel there is no automatic rule to overrule, because the signal
    /// such a rule would read — what is in each repository — is exactly the
    /// poll a collapsed section refuses to pay for.
    @State private var expanded: Set<String> = []

    private var selectedTab: SidebarTabModel? {
        tabManager.models.first { $0.isSelected }
    }

    private var discovered: [String]? {
        (selectedTab?.pwd).flatMap { git.workspaceRepos[$0] }
    }

    /// The scan hasn't answered yet. Distinguished from a folder that really
    /// holds nothing so the "no git repository" message doesn't flash on
    /// screen for a moment every time you switch to a workspace tab.
    private var isScanning: Bool {
        (inputs.repoRoot ?? "").isEmpty
            && !(inputs.pwd ?? "").isEmpty
            && inputs.discovered == nil
    }

    private var polledRoots: [String] {
        scope.polled(expanded: expanded)
    }

    var body: some View {
        content
            .onAppear { syncScope() }
            /// Failures arrive as a sheet, exactly like the Git panel's: a
            /// git refusal is paragraphs, and paragraphs do not fit a 240pt
            /// column. It stays on the panel rather than in a section
            /// because a failure belongs to the window, not to one
            /// repository's row.
            .sheet(item: $center.lastError) { error in
                GitFailureSheet(operation: error.operation, failure: error.failure)
            }
            /// The lists change from outside constantly — the terminal next
            /// door is where `git worktree add` may well be typed. Nothing
            /// publishes that, so the panel polls while on screen; every
            /// request is a no-op until its TTL is up, and only what is open
            /// is asked about at all. See `WorktreeScope.polled`.
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                for root in polledRoots {
                    center.requestList(commonRoot: root)
                    center.requestMerged(commonRoot: root)
                    for worktree in center.list(forRoot: root) where !worktree.isBare {
                        git.requestStatus(root: worktree.path)
                    }
                }
            }
            .onChange(of: tabManager.groupingVersion) { _ in syncScope() }
            .onChange(of: refresh.token) { _ in forceRefresh() }
            /// The workspace scan answers on its own thread, long after the
            /// tab that triggered it stopped changing.
            .onChange(of: discovered) { _ in syncScope() }
            .onReceive(
                Publishers.MergeMany(tabManager.models.map { $0.objectWillChange })
            ) { _ in
                DispatchQueue.main.async { syncScope() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch scope {
        case .repository(let root):
            family(root, style: .standalone)

        case .workspace(let roots):
            sections(roots)

        case .none:
            if selectedTab == nil {
                emptyState("No terminal selected")
            } else if isScanning {
                scanningState
            } else {
                emptyState("No git repository here or below")
            }
        }
    }

    private func family(_ root: String, style: WorktreeFamilyStyle) -> WorktreeFamilyView {
        WorktreeFamilyView(
            commonRoot: root,
            style: style,
            tabManager: tabManager,
            editorCenter: editorCenter,
            onNewTerminal: onNewTerminal,
            onNewAgentTab: onNewAgentTab)
    }

    private func sections(_ roots: [String]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(roots.enumerated()), id: \.element) { index, root in
                    if needsDivider(above: index, in: roots) {
                        Divider()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }

                    family(root, style: .section(
                        isExpanded: expanded.contains(root),
                        onToggle: { toggle(root) }
                    ))
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.automatic)
    }

    /// The Git panel's rule, reused rather than restated: the question of
    /// where a rule belongs between two disclosure sections has one answer,
    /// and two copies of it would drift.
    private func needsDivider(above index: Int, in roots: [String]) -> Bool {
        GitRepoExpansion.needsDivider(above: index, expanded: roots.map(expanded.contains))
    }

    private func emptyState(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var scanningState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Looking for repositories…")
                .font(palette.font(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Expansion

    /// Opening a section is what pays for its list, so the request goes here
    /// rather than waiting for the next tick: two seconds of an empty section
    /// after a click reads as a click that missed.
    private func toggle(_ root: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            if expanded.contains(root) {
                expanded.remove(root)
            } else {
                expanded.insert(root)
            }
        }

        guard expanded.contains(root) else { return }
        center.requestList(commonRoot: root)
        center.requestMerged(commonRoot: root)
    }

    // MARK: Syncing

    /// Follows the selected terminal: its repository's family if it is in
    /// one, else the families of the repositories under its folder.
    private func syncScope() {
        let tab = selectedTab
        let pwd = tab?.pwd
        let next = ScopeInputs(
            repoRoot: tab?.repoRoot,
            pwd: pwd,
            discovered: pwd.flatMap { git.workspaceRepos[$0] })

        var resolved = scope
        if next != inputs {
            /// A different folder is a different set of sections, so the
            /// choices made about the old ones don't apply.
            if next.repoRoot != inputs.repoRoot || next.pwd != inputs.pwd {
                expanded = []
            }
            inputs = next
            resolved = WorktreeScope.resolve(
                GitPanelScope.resolve(
                    repoRoot: next.repoRoot,
                    pwd: next.pwd,
                    discovered: next.discovered),
                commonRoot: { GitCommonDir.resolve(from: $0) })
            scope = resolved
        }

        if (next.repoRoot ?? "").isEmpty, let pwd, !pwd.isEmpty {
            git.requestWorkspaceRepos(root: pwd)
        }

        /// Only the flat case is asked for eagerly. A workspace's sections
        /// all start collapsed, and each pays for itself when opened.
        if case .repository(let root) = resolved {
            center.requestList(commonRoot: root)
            center.requestMerged(commonRoot: root)
        }
    }

    private func forceRefresh() {
        if (inputs.repoRoot ?? "").isEmpty, let pwd = inputs.pwd, !pwd.isEmpty {
            git.requestWorkspaceRepos(root: pwd, force: true)
        }

        for root in polledRoots {
            center.requestList(commonRoot: root, force: true)
            center.requestMerged(commonRoot: root, force: true)
            for worktree in center.list(forRoot: root) where !worktree.isBare {
                git.requestStatus(root: worktree.path, force: true)
            }
        }
    }
}
