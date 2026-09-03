import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The single active drop-insertion target for the whole sidebar. One
/// shared instance (instead of per-row state) means a missed dropExited
/// can never leave a stale insertion indicator behind: the next
/// dropUpdated anywhere replaces it, and every performDrop clears it.
final class SidebarDragState: ObservableObject {
    @Published private(set) var target: (row: ObjectIdentifier, after: Bool)?

    private var expiry: DispatchWorkItem?

    /// How long the indicator outlives the last drag update.
    private static let expiryDelay: TimeInterval = 0.6

    /// Places the insertion indicator, and arms its expiry.
    ///
    /// Drop delegates report where the indicator goes, but nothing reports a
    /// drag that ended *without* a drop — released over a gap, or cancelled
    /// — which left the indicator on screen for good. A live drag keeps
    /// refreshing this (AppKit sends periodic updates even while the pointer
    /// holds still), so letting it lapse is what reliably clears it.
    func mark(row: ObjectIdentifier, after: Bool) {
        if target?.row != row || target?.after != after {
            target = (row: row, after: after)
        }

        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.target = nil
            self?.expiry = nil
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.expiryDelay, execute: work)
    }

    /// Clears the indicator. Pass `row` to only clear it when that row is
    /// the one currently marked, so a row being exited doesn't wipe the
    /// indicator the row being entered just placed.
    func clear(row: ObjectIdentifier? = nil) {
        if let row, target?.row != row { return }
        expiry?.cancel()
        expiry = nil
        if target != nil { target = nil }
    }
}

enum SidebarMetrics {
    /// The one gap used between every item in the list — groups, loose
    /// terminals, and tabs within a group — so the whole sidebar keeps a
    /// single rhythm regardless of what an item is.
    static let itemSpacing: CGFloat = 8
}

/// The vertical tab sidebar: tabs grouped into user-defined sections.
struct SidebarView: View {
    @ObservedObject var tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore
    @ObservedObject var layout: SidebarLayoutModel

    /// This window's open files, so the file tree can mark the one on screen.
    @ObservedObject var editorCenter: EditorCenter

    @StateObject private var dragState = SidebarDragState()

    /// Creates a terminal tab inside the given group (nil for ungrouped),
    /// following the group's working-directory rule.
    var onNewTabInGroup: (SidebarGroup?) -> Void = { _ in }

    /// Same as `onNewTabInGroup`, with a Claude session started in it.
    var onNewClaudeTabInGroup: (SidebarGroup?) -> Void = { _ in }

    /// Same as `onNewTabInGroup`, with a Codex session started in it.
    var onNewCodexTabInGroup: (SidebarGroup?) -> Void = { _ in }
    var onNewOpenCodeTabInGroup: (SidebarGroup?) -> Void = { _ in }
    var onNewAntigravityTabInGroup: (SidebarGroup?) -> Void = { _ in }
    var onNewKimiTabInGroup: (SidebarGroup?) -> Void = { _ in }
    var onNewPiTabInGroup: (SidebarGroup?) -> Void = { _ in }

    /// Opens a terminal directly beside the selected one — same group, or
    /// ungrouped if that's where the selection lives — and hands back its
    /// surface. The panels open every file in one of these; see
    /// `FileOpener.openInTerminal`.
    var onSpawnTerminalBesideSelection: () -> Ghostty.SurfaceView? = { nil }

    /// Opens a file in this window's editor pane, which takes the
    /// terminal's place while anything is open.
    var onOpenInEditor: (URL) -> Void = { _ in }

    /// See `GitRepoView.onOpenDiff`. Not forwarded to the file explorer,
    /// which has no changes to show.
    var onOpenDiff: ((URL) -> Void)?

    /// See `GitRepoView.onOpenBranchDiff`.
    var onOpenBranchDiff: ((URL, String) -> Void)?

    /// List animations are suspended while the sidebar first populates.
    private var listAnimation: Animation? {
        tabManager.animationsEnabled ? .snappy(duration: 0.22) : nil
    }

    /// One rendered group section and the tabs resolved into it, in
    /// sidebar display order.
    private struct Section: Identifiable {
        let group: SidebarGroup
        let tabs: [SidebarTabModel]

        var id: UUID { group.id }
    }

    private var resolved: (sections: [Section], ungrouped: [SidebarTabModel]) {
        var byGroup: [UUID: [SidebarTabModel]] = [:]
        var ungrouped: [SidebarTabModel] = []

        for tab in tabManager.models {
            if let group = store.resolveGroup(surfaceId: tab.surfaceId, pwd: tab.pwd) {
                byGroup[group.id, default: []].append(tab)
            } else {
                ungrouped.append(tab)
            }
        }

        let sections = store.groups.map { group in
            Section(
                group: group,
                tabs: store.sorted(byGroup[group.id] ?? [], id: \.surfaceId)
            )
        }
        return (sections, store.sorted(ungrouped, id: \.surfaceId))
    }

    var body: some View {
        // No background of its own: the window paints the theme color,
        // opacity and blur, so the sidebar always matches the terminal.
        //
        // The padding is the titlebar strip in fullscreen, where the window
        // stops reserving it and the traffic lights would otherwise land on
        // the pane switcher; it is zero everywhere else. Padding rather than
        // a shorter hosting view, because that view's layer is what paints
        // the strip on the sidebar's half — moved down, the strip would go
        // back to showing the bare window.
        expanded
            .padding(.top, layout.titlebarInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            /// A guard, not a layout: a pane taller than the sidebar is a bug
            /// in that pane, and the Git panel was one — but the way it
            /// presented was content drawn over the pane switcher and under
            /// the window's traffic lights, which reads as the whole app being
            /// broken rather than as one list being too long. Clipped, the
            /// next pane to overflow merely loses its ends.
            .clipped()
    }

    /// The panels the user has switched on. Read through `@AppStorage` so
    /// the sidebar follows the setting live — `SidebarPane.isEnabled` goes
    /// to `UserDefaults` directly, which SwiftUI has no way to observe.
    @AppStorage("SidebarShowFilesPane") private var showFilesPane = true
    @AppStorage("SidebarShowGitPane") private var showGitPane = true
    @AppStorage("SidebarShowWorktreesPane") private var showWorktreesPane = true

    private var enabledPanes: [SidebarPane] {
        SidebarPane.allCases.filter { pane in
            switch pane {
            case .terminals: return true
            case .files: return showFilesPane
            case .git: return showGitPane
            case .worktrees: return showWorktreesPane
            }
        }
    }

    /// Falls back to terminals when the selected panel has been switched
    /// off. Resolved here rather than by writing back to `selectedPane`,
    /// because turning the last extra panel off also hides the tab bar —
    /// and a correction that lives in the bar would never run, leaving the
    /// sidebar stuck on a panel with no way back to the terminals.
    private var visiblePane: SidebarPane {
        enabledPanes.contains(layout.selectedPane) ? layout.selectedPane : .terminals
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            if enabledPanes.count > 1 {
                SidebarPaneTabBar(selection: $layout.selectedPane, panes: enabledPanes)
            }

            switch visiblePane {
            case .terminals:
                terminalList
            case .files:
                FileExplorerView(
                    tabManager: tabManager,
                    store: store,
                    onSpawnTerminal: onSpawnTerminalBesideSelection,
                    onOpenInEditor: onOpenInEditor,
                    editorCenter: editorCenter
                )
            case .git:
                GitPanelView(
                    tabManager: tabManager,
                    editorCenter: editorCenter,
                    onSpawnTerminal: onSpawnTerminalBesideSelection,
                    onOpenInEditor: onOpenInEditor,
                    onOpenDiff: onOpenDiff,
                    onOpenBranchDiff: onOpenBranchDiff
                )
            case .worktrees:
                WorktreePanelView(
                    tabManager: tabManager,
                    editorCenter: editorCenter,
                    /// The panel follows one terminal, so that terminal's
                    /// group is where a worktree opened from here belongs.
                    onNewTerminal: { path in
                        layout.onNewWorktreeTab(path, selectedGroupId)
                    },
                    onNewAgentTab: { path, agent in
                        layout.onNewWorktreeAgentTab(path, agent, selectedGroupId)
                    }
                )
            }
        }
    }

    /// The group of the terminal the panels are following, if it is in one.
    private var selectedGroupId: UUID? {
        guard let tab = tabManager.models.first(where: { $0.isSelected }) else { return nil }
        return store.resolveGroup(surfaceId: tab.surfaceId, pwd: tab.pwd)?.id
    }

    /// Built here rather than inline in `terminalList`.
    ///
    /// Thirteen arguments inside a `ForEach` inside a `VStack` inside a
    /// `ScrollView` is past what the type checker will solve in the time it
    /// allows itself — it gave up on the whole list, not on this call.
    private func groupSection(_ section: Section) -> some View {
        SidebarGroupSection(
            group: section.group,
            tabs: section.tabs,
            tabManager: tabManager,
            store: store,
            dragState: dragState,
            onNewTab: onNewTabInGroup,
            onNewClaudeTab: onNewClaudeTabInGroup,
            onNewCodexTab: onNewCodexTabInGroup,
            onNewOpenCodeTab: onNewOpenCodeTabInGroup,
            onNewAntigravityTab: onNewAntigravityTabInGroup,
            onNewKimiTab: onNewKimiTabInGroup,
            onNewPiTab: onNewPiTabInGroup,
            editorCenter: editorCenter,
            onNewWorktreeTab: layout.onNewWorktreeTab,
            onNewWorktreeTabInGroup: layout.onNewWorktreeTabInGroup
        )
    }

    private var terminalList: some View {
        VStack(spacing: 0) {
            ScrollView {
                let content = resolved

                VStack(spacing: SidebarMetrics.itemSpacing) {
                    ForEach(content.sections) { section in
                        groupSection(section)
                            .transition(.opacity)
                    }

                    // Same spacing as between groups: every item in the
                    // list sits on the one rhythm, whether it's a group or
                    // a loose terminal.
                    ForEach(content.ungrouped) { tab in
                        SidebarTabRow(
                            tab: tab,
                            groupId: nil,
                            tabManager: tabManager,
                            store: store,
                            dragState: dragState,
                            editorCenter: editorCenter,
                            onNewWorktreeTab: layout.onNewWorktreeTab
                        )
                        .transition(.opacity)
                    }
                }
                .padding(8)
                .animation(listAnimation, value: content.sections.map(\.id))
                .animation(listAnimation, value: store.tabOrder)
                .animation(listAnimation, value: tabManager.models.map(\.id))
                .background(alignment: .top) { OverlayScrollers() }
            }
            .scrollIndicators(.automatic)
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                appendDroppedToUngrouped(providers)
            }
        }
    }

    /// Drop on the list background: tabs move to the end ungrouped,
    /// groups move to the end of the group list.
    private func appendDroppedToUngrouped(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        dragState.clear()
        let lastUngrouped = resolved.ungrouped.last?.surfaceId
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String else { return }
            Task { @MainActor in
                switch SidebarDragPayload(string) {
                case .tab(let surfaceId):
                    if let lastUngrouped, lastUngrouped != surfaceId {
                        store.insert(surfaceId: surfaceId, near: lastUngrouped, after: true, groupId: nil)
                    } else {
                        store.assign(surfaceId: surfaceId, to: nil)
                    }
                case .group(let movedId):
                    store.moveGroup(movedId, toIndex: store.groups.count)
                case nil:
                    break
                }
            }
        }
        return true
    }

}

/// The sidebar action icons rendered inside the window titlebar (as a
/// leading titlebar accessory), trailing-aligned so they hug the
/// sidebar's edge like a native toolbar.
struct SidebarTitlebarChrome: View {
    @ObservedObject var store: SidebarGroupStore
    @ObservedObject var layout: SidebarLayoutModel

    /// Both for one button: the worktree action needs to know which
    /// repository the selected terminal is in, and the component that draws
    /// it is the same one the rows use — which reasons about documents,
    /// because on a row it can migrate. From here it only ever opens a new
    /// terminal.
    @ObservedObject var tabManager: SidebarTabManager
    @ObservedObject var editorCenter: EditorCenter

    @ObservedObject var collapse: SidebarCollapseState = .shared

    @State private var isCreatingGroup = false
    @State private var isHovered = false
    @State private var groupingWorktree: GitWorktree?

    /// Mirrors `SidebarView`'s own fallback: a panel switched off in
    /// settings must not leave its buttons behind in the titlebar.
    @AppStorage("SidebarShowFilesPane") private var showFilesPane = true
    @AppStorage("SidebarShowGitPane") private var showGitPane = true
    @AppStorage("SidebarShowWorktreesPane") private var showWorktreesPane = true
    @AppStorage(AgentButtonDefaults.key(.chrome, .claude)) private var showClaude = AgentButtonDefaults.isShown(.claude)
    @AppStorage(AgentButtonDefaults.key(.chrome, .codex)) private var showCodex = AgentButtonDefaults.isShown(.codex)
    @AppStorage(AgentButtonDefaults.key(.chrome, .opencode)) private var showOpenCode = AgentButtonDefaults.isShown(.opencode)
    @AppStorage(AgentButtonDefaults.key(.chrome, .antigravity)) private var showAntigravity = AgentButtonDefaults.isShown(.antigravity)
    @AppStorage(AgentButtonDefaults.key(.chrome, .kimi)) private var showKimi = AgentButtonDefaults.isShown(.kimi)
    @AppStorage(AgentButtonDefaults.key(.chrome, .pi)) private var showPi = AgentButtonDefaults.isShown(.pi)

    /// Whether the pane actions (new terminal, new Claude session, new
    /// group, refresh) stay visible without a hover — off by default,
    /// matching the behavior before this existed. The sidebar show/hide
    /// button is exempt: hiding it behind a hover would leave no visible
    /// way to bring a collapsed sidebar back.
    @AppStorage("SidebarChromeAlwaysShowActions") private var alwaysShowActions = false
    @AppStorage("SidebarChromeShowWorktree") private var showWorktree = true

    /// The terminal the whole sidebar is following, which is the one whose
    /// repository the chrome's actions are about.
    private var selectedTab: SidebarTabModel? {
        tabManager.models.first { $0.isSelected }
    }

    /// That terminal's group, if it is in one. A worktree opened from up here
    /// is opened about the terminal below, so it lands where that terminal is.
    private var selectedGroupId: UUID? {
        guard let tab = selectedTab else { return nil }
        return store.resolveGroup(surfaceId: tab.surfaceId, pwd: tab.pwd)?.id
    }

    private var visiblePane: SidebarPane {
        switch layout.selectedPane {
        case .files where !showFilesPane: return .terminals
        case .git where !showGitPane: return .terminals
        case .worktrees where !showWorktreesPane: return .terminals
        default: return layout.selectedPane
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            if !collapse.isCollapsed {
                paneActions
                    .opacity(alwaysShowActions || isHovered ? 1 : 0)
                    .allowsHitTesting(alwaysShowActions || isHovered)
                    // The tab bar wraps the pane change in `withAnimation`,
                    // and that animation reached in here too: switching
                    // panels animated the whole row, sliding every button
                    // back into place from the left. Which buttons apply is
                    // a toggle, not a movement.
                    .transaction { $0.animation = nil }
            }

            SidebarChromeButton(
                icon: "sidebar.left",
                help: collapse.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
            ) {
                collapse.isCollapsed.toggle()
            }
        }
        .animation(.easeOut(duration: 0.15), value: collapse.isCollapsed)
        .onHover { isHovered = $0 }
        /// Asked for here rather than from the button, which draws nothing
        /// at all while the answer is "no repositories" — a view that is not
        /// on screen cannot ask the question that would put it there.
        /// `GitCenter` caches per folder and refuses folders too broad to
        /// walk, so this is one scan per workspace per launch.
        .task(id: workspaceScanRoot) {
            guard let root = workspaceScanRoot else { return }
            GitCenter.shared.requestWorkspaceRepos(root: root)
        }
    }

    /// The selected terminal's folder, when the terminal is not inside a
    /// repository. Nil is the answer that skips the scan entirely.
    private var workspaceScanRoot: String? {
        guard (selectedTab?.repoRoot ?? "").isEmpty else { return nil }
        guard let pwd = selectedTab?.pwd, !pwd.isEmpty else { return nil }
        return pwd
    }

    /// The buttons here belong to whichever panel is showing — creating a
    /// terminal makes no sense while browsing files, and refreshing a tree
    /// makes none while looking at terminals.
    ///
    /// One `if`/`else` rather than a `switch` over the three panes, so that
    /// what the panels have in common stays put. Refresh is the same button
    /// in Files and in Git; under a `switch` it lived in a different branch
    /// in each, which made SwiftUI tear it down and build a new one just
    /// for moving between two panels that both show it.
    @ViewBuilder
    private var paneActions: some View {
        if visiblePane == .terminals {
            SidebarChromeButton(icon: "plus", help: "New Terminal") {
                layout.onNewTab()
            }
            if showClaude {
                SidebarIconButton(help: "New Claude Session") {
                    layout.onNewClaudeTab()
                } label: {
                    ClaudeIcon(size: 12)
                }
            }
            if showCodex {
                SidebarIconButton(help: "New Codex Session") {
                    layout.onNewCodexTab()
                } label: {
                    CodexIcon(size: 12)
                }
            }
            if showOpenCode {
                SidebarIconButton(help: "New OpenCode Session") {
                    layout.onNewOpenCodeTab()
                } label: {
                    OpenCodeIcon(size: 12)
                }
            }
            if showAntigravity {
                SidebarIconButton(help: "New Antigravity Session") {
                    layout.onNewAntigravityTab()
                } label: {
                    AntigravityIcon(size: 12)
                }
            }
            if showKimi {
                SidebarIconButton(help: "New Kimi Code Session") {
                    layout.onNewKimiTab()
                } label: {
                    KimiIcon(size: 12)
                }
            }
            if showPi {
                SidebarIconButton(help: "New Pi Session") {
                    layout.onNewPiTab()
                } label: {
                    PiIcon(size: 12)
                }
            }
            if showWorktreesPane {
                WorktreeEntryButton(
                    entry: .chrome,
                    isEnabled: showWorktree,
                    repoRoot: selectedTab?.repoRoot,
                    /// The folder the terminal is in, for when it is not a
                    /// checkout itself: a workspace of repositories side by
                    /// side is somewhere to open a worktree from, which is
                    /// what the Worktrees panel has always said about the
                    /// same terminal.
                    scanRoot: selectedTab?.pwd,
                    currentPath: selectedTab?.pwd,
                    isIdle: true,
                    hasLiveAgent: false,
                    editorCenter: editorCenter,
                    terminalPwds: tabManager.models.compactMap(\.pwd),
                    onMigrate: { _, _ in },
                    onNewTerminal: { path in
                        layout.onNewWorktreeTab(path, selectedGroupId)
                    },
                    onCreateGroup: { worktree in groupingWorktree = worktree },
                    onViewFile: { path in editorCenter.open(URL(fileURLWithPath: path)) },
                    isRevealed: true)
                /// Every terminal working in that worktree, not only the
                /// selected one: the gesture is about the worktree.
                .sheet(item: $groupingWorktree) { worktree in
                    SidebarGroupEditor(
                        group: nil,
                        store: store,
                        assignSurfaceIds: tabManager.models
                            .filter { GitWorktreeMembership.contains(pwd: $0.pwd, root: worktree.path) }
                            .compactMap(\.surfaceId),
                        initialName: worktree.branch
                            ?? (worktree.path as NSString).lastPathComponent
                    )
                }
            }

            SidebarChromeButton(icon: "folder.badge.plus", help: "New Group") {
                isCreatingGroup = true
            }
            .sheet(isPresented: $isCreatingGroup) {
                SidebarGroupEditor(group: nil, store: store)
            }
        } else {
            SidebarChromeButton(icon: "arrow.clockwise", help: "Refresh") {
                switch visiblePane {
                case .files: FileExplorerRefresh.shared.request()
                case .git: GitPanelRefresh.shared.request()
                case .worktrees: WorktreePanelRefresh.shared.request()
                case .terminals: break
                }
            }
        }
    }
}

/// The hit area and hover treatment shared by every icon button in the
/// sidebar. Group headers and tab rows reuse this so their icons are as
/// easy to hit as the chrome row's — undersized targets there meant a near
/// miss landed on the row or header gesture behind the button instead.
struct SidebarIconButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label().sidebarIconChip()
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension View {
    /// The hover treatment every icon control in the sidebar shares — one
    /// hit area, one corner radius, one highlight. Kept as a modifier
    /// rather than living only inside `SidebarIconButton` so the things
    /// that can't be a `Button` still look and feel identical to the ones
    /// that can.
    ///
    /// A `Menu` is the exception and must use `SidebarIconMenu` instead —
    /// see there for why.
    func sidebarIconChip() -> some View {
        modifier(SidebarIconChip())
    }
}

/// "How many of these are there" — terminals in a group, changed files in
/// a section, commits waiting to be pushed. One capsule for all of them so
/// a count always looks like a count, instead of each panel inventing its
/// own treatment.
struct SidebarCountBadge: View {
    let count: Int

    /// Drawn before the number, for counts that need to say *which* kind.
    var symbol: String?

    @ObservedObject private var palette: ThemePalette = .shared

    var body: some View {
        HStack(spacing: 2) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(verbatim: "\(count)")
                .font(palette.font(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(.quaternary))
    }
}

enum SidebarIconChipMetrics {
    static let width: CGFloat = 24
    static let height: CGFloat = 22
    static let cornerRadius: CGFloat = 5

    /// Breathing room between a chip and the edge of the row it sits in.
    /// A row exactly as tall as its chip puts the highlight flush against
    /// the row's own background, which reads as a rendering seam rather
    /// than a button.
    static let rowInset: CGFloat = 3

    /// The height a list row needs for its chips to sit inside it.
    static var rowHeight: CGFloat { height + rowInset * 2 }
}

private struct SidebarIconChip: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .frame(width: SidebarIconChipMetrics.width, height: SidebarIconChipMetrics.height)
            .contentShape(Rectangle())
            .sidebarIconChipHighlight(isHovered)
            .onHover { isHovered = $0 }
    }
}

extension View {
    fileprivate func sidebarIconChipHighlight(_ isHovered: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: SidebarIconChipMetrics.cornerRadius)
                .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
    }
}

/// A panel's overflow menu, wearing the same chip as the icon buttons
/// beside it.
///
/// The chip can't ride on the menu's *label* the way it does on a button's:
/// `Menu` lays its own tracking area over the label to drive highlighting
/// and menu opening, so an `.onHover` attached in there never fires and the
/// highlight simply never appears — which is exactly how the panel headers
/// ended up as the one control in the sidebar with no hover. Observing the
/// hover on the wrapper and drawing the highlight behind the menu gets the
/// same look without fighting for the same events.
struct SidebarIconMenu<Content: View>: View {
    let help: String
    var icon: String = "ellipsis"
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: SidebarIconChipMetrics.width, height: SidebarIconChipMetrics.height)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Pinned again on the outside: `fixedSize` hands the menu its own
        // intrinsic height, which is shorter than the label's frame, so
        // without this the highlight came out squatter than every other
        // chip in the same row.
        .frame(width: SidebarIconChipMetrics.width, height: SidebarIconChipMetrics.height)
        .sidebarIconChipHighlight(isHovered)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// A small borderless icon button for the sidebar chrome row.
private struct SidebarChromeButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        SidebarIconButton(help: help, action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// A group block: tinted header with icon, name and color dot, a colored
/// border around the whole block, and the tab rows when expanded.
private struct SidebarGroupSection: View {
    let group: SidebarGroup
    let tabs: [SidebarTabModel]
    let tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore
    let dragState: SidebarDragState
    var onNewTab: (SidebarGroup?) -> Void = { _ in }
    var onNewClaudeTab: (SidebarGroup?) -> Void = { _ in }
    var onNewCodexTab: (SidebarGroup?) -> Void = { _ in }
    var onNewOpenCodeTab: (SidebarGroup?) -> Void = { _ in }
    var onNewAntigravityTab: (SidebarGroup?) -> Void = { _ in }
    var onNewKimiTab: (SidebarGroup?) -> Void = { _ in }
    var onNewPiTab: (SidebarGroup?) -> Void = { _ in }

    /// Passed straight through to the rows, which is the only reason this
    /// view knows about either: a group header draws no documents and opens
    /// no terminals of its own beyond the one button below.
    @ObservedObject var editorCenter: EditorCenter
    let onNewWorktreeTab: (String, UUID?) -> Void

    /// The header's own button, which must put the terminal *in this group*.
    /// Pressing a button on a group and watching the terminal appear at the
    /// bottom of the list, outside it, is the gesture doing half of what it
    /// said.
    let onNewWorktreeTabInGroup: (SidebarGroup, String) -> Void

    @ObservedObject private var palette: ThemePalette = .shared

    @AppStorage("SidebarGroupShowPullRequests") private var showPullRequests = true
    @AppStorage(AgentButtonDefaults.key(.groupHeader, .claude)) private var showClaude = AgentButtonDefaults.isShown(.claude)
    @AppStorage(AgentButtonDefaults.key(.groupHeader, .codex)) private var showCodex = AgentButtonDefaults.isShown(.codex)
    @AppStorage(AgentButtonDefaults.key(.groupHeader, .opencode)) private var showOpenCode = AgentButtonDefaults.isShown(.opencode)
    @AppStorage(AgentButtonDefaults.key(.groupHeader, .antigravity)) private var showAntigravity = AgentButtonDefaults.isShown(.antigravity)
    @AppStorage(AgentButtonDefaults.key(.groupHeader, .kimi)) private var showKimi = AgentButtonDefaults.isShown(.kimi)
    @AppStorage(AgentButtonDefaults.key(.groupHeader, .pi)) private var showPi = AgentButtonDefaults.isShown(.pi)
    @AppStorage("SidebarGroupShowNewTerminal") private var showNewTerminal = true
    @AppStorage("SidebarGroupShowWorktree") private var showWorktree = true
    @AppStorage("SidebarGroupShowCount") private var showCount = true

    /// Whether the three action icons above stay visible without a hover —
    /// off by default, matching the behavior before this existed.
    @AppStorage("SidebarGroupAlwaysShowActions") private var alwaysShowActions = false

    @State private var isDropTarget = false
    @State private var isEditing = false
    @State private var isHeaderHovered = false

    /// How wide the header's whole trailing cluster is — buttons and count —
    /// measured by the layout that draws it.
    @State private var clusterWidth: CGFloat = 0
    @State private var isShowingPRs = false

    /// The terminals "Delete Group and Close Terminals" is asking about, or
    /// nil while nothing is being asked.
    @State private var pendingClose: PendingGroupClose?

    /// What the confirmation was written about, measured once when the menu
    /// item is picked rather than on every render.
    ///
    /// `needsConfirmQuit` crosses into libghostty for every surface, and this
    /// header re-renders on hover, on selection and on every metadata tick —
    /// asking there would pay for a number nobody is reading. Measuring once
    /// also pins the sheet to the set the reader was shown: a terminal that
    /// finishes its build while the sheet is up does not quietly change the
    /// sentence they are answering.
    private struct PendingGroupClose {
        let tabs: [SidebarTabModel]

        /// How many of `tabs` the core says still have something running.
        let runningProcesses: Int
    }

    private var accent: Color? { group.accentColor }
    private var collapsed: Bool { group.collapsed }

    /// Whose repository the header's worktree button reasons about.
    ///
    /// A group's tabs can in principle sit in different repositories, and
    /// there is no single right answer then — so the first one that is in a
    /// repository at all, which for the ordinary group is every one of them.
    /// Nothing is typed into it: the button only ever opens a new terminal.
    private var representativeTab: SidebarTabModel? {
        tabs.first { !($0.repoRoot ?? "").isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !collapsed {
                VStack(spacing: SidebarMetrics.itemSpacing) {
                    ForEach(tabs) { tab in
                        SidebarTabRow(
                            tab: tab,
                            groupId: group.id,
                            tabManager: tabManager,
                            store: store,
                            dragState: dragState,
                            editorCenter: editorCenter,
                            onNewWorktreeTab: onNewWorktreeTab
                        )
                    }
                    if tabs.isEmpty {
                        Text("No tabs")
                            .font(palette.captionFont)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                }
                .padding(4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((accent ?? .secondary).opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTarget
                        ? (accent ?? palette.accent ?? .accentColor)
                        : (accent ?? .secondary).opacity(0.35),
                    lineWidth: isDropTarget ? 2 : 1
                )
        )
        .onDrop(of: [.plainText], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .animation(.snappy(duration: 0.2), value: collapsed)
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .sheet(isPresented: $isEditing) {
            SidebarGroupEditor(group: group, store: store)
        }
        .confirmationDialog(
            closeConfirmationTitle,
            isPresented: Binding(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } }
            ),
            titleVisibility: .visible
        ) {
            closeConfirmationButtons
        } message: {
            Text(closeConfirmationMessage)
        }
    }

    /// The destructive button repeats the menu item word for word, so the
    /// reader confirms the sentence they picked.
    ///
    /// Cancel takes both the cancel role and the default action, which is the
    /// one place this sheet departs from the file explorer's delete: that one
    /// moves a file to the Trash and the Trash gives it back, while this kills
    /// processes and nothing gives those back. Return must not be the key that
    /// does it.
    @ViewBuilder
    private var closeConfirmationButtons: some View {
        Button(deleteWithTerminalsTitle, role: .destructive) {
            if let pendingClose {
                deleteGroupAndCloseTerminals(pendingClose)
            }
            pendingClose = nil
        }
        Button("Cancel", role: .cancel) { pendingClose = nil }
            .keyboardShortcut(.defaultAction)
    }

    /// The number every sentence about this is written around: the snapshot
    /// once one exists, the rows on screen before that.
    ///
    /// Both spellings matter. The menu item is read before anything is
    /// snapshotted and must name what is on screen; the button is read after,
    /// and must name what the title above it just named — not a count that
    /// moved because a terminal exited while the sheet was up.
    private var closingTerminalCount: Int {
        pendingClose?.tabs.count ?? tabs.count
    }

    /// "1 Terminal" / "4 Terminals", so the count reaches the reader in the
    /// menu, in the title and on the button they press.
    private var terminalCountPhrase: String {
        closingTerminalCount == 1 ? "1 Terminal" : "\(closingTerminalCount) Terminals"
    }

    private var deleteWithTerminalsTitle: String {
        "Delete Group and Close \(terminalCountPhrase)"
    }

    private var closeConfirmationTitle: String {
        let count = closingTerminalCount
        let terminals = count == 1 ? "its terminal" : "its \(count) terminals"
        return "Delete \u{201C}\(group.name)\u{201D} and close \(terminals)?"
    }

    /// Written for a reader who is half paying attention: what goes, what it
    /// costs, and that nothing brings it back.
    ///
    /// The running-process sentence borrows the wording the app already uses
    /// when a single tab is closed on a live process, because it is the same
    /// fact — this is only the batch spelling of it, as `Close Other Tabs`
    /// is. There is no undo: the tab-restore each close registers brings back
    /// a terminal in the same directory, never the process that was running
    /// in it.
    private var closeConfirmationMessage: String {
        guard let pendingClose else { return "" }
        let count = pendingClose.tabs.count
        let terminals = count == 1 ? "its terminal" : "its \(count) terminals"
        let base = "Deleting the group closes \(terminals). This cannot be undone."

        guard pendingClose.runningProcesses > 0 else { return base }
        let running = pendingClose.runningProcesses == 1
            ? "One still has a running process, and that process will be killed."
            : "\(pendingClose.runningProcesses) still have a running process, "
                + "and those processes will be killed."
        return "\(base) \(running)"
    }

    /// The header's buttons, which come and go with the hover.
    ///
    /// Kept apart from the header so the layout can place them either in the
    /// row or over it — see `header`, and `SidebarTabRow.body` for why a row
    /// must not reserve width for buttons it is not drawing. A group's
    /// description was the visible cost here: two lines of it where one line
    /// fits, to leave room for eight icons that were not on screen.
    private var headerActions: some View {
        HStack(spacing: 6) {
                    if showPullRequests {
                        SidebarIconButton(help: "Pull Requests in Group") {
                            isShowingPRs = true
                        } label: {
                            GitIcon(size: 11)
                                .foregroundStyle(.secondary)
                        }
                        .opacity(alwaysShowActions || isHeaderHovered ? 1 : 0)
                        .allowsHitTesting(alwaysShowActions || isHeaderHovered)
                        .popover(isPresented: $isShowingPRs) {
                            GroupPRListView(
                                group: group,
                                openTabRoots: Array(Set(tabs.compactMap(\.repoRoot)))
                            )
                        }
                    }
                    if showClaude {
                        SidebarIconButton(help: "New Claude Session in Group") {
                            onNewClaudeTab(group)
                        } label: {
                            ClaudeIcon(size: 12)
                        }
                        .opacity(alwaysShowActions || isHeaderHovered ? 1 : 0)
                        .allowsHitTesting(alwaysShowActions || isHeaderHovered)
                    }
                    if showCodex {
                        SidebarIconButton(help: "New Codex Session in Group") {
                            onNewCodexTab(group)
                        } label: {
                            CodexIcon(size: 12)
                        }
                        .opacity(alwaysShowActions || isHeaderHovered ? 1 : 0)
                        .allowsHitTesting(alwaysShowActions || isHeaderHovered)
                    }
                    if showOpenCode {
                        SidebarIconButton(help: "New OpenCode Session in Group") {
                            onNewOpenCodeTab(group)
                        } label: {
                            OpenCodeIcon(size: 12)
                        }
                        .opacity(alwaysShowActions || isHeaderHovered ? 1 : 0)
                        .allowsHitTesting(alwaysShowActions || isHeaderHovered)
                    }
                    if showAntigravity {
                        SidebarIconButton(help: "New Antigravity Session in Group") {
                            onNewAntigravityTab(group)
                        } label: {
                            AntigravityIcon(size: 12)
                        }
                        .opacity(alwaysShowActions || isHeaderHovered ? 1 : 0)
                        .allowsHitTesting(alwaysShowActions || isHeaderHovered)
                    }
                    if showKimi {
                        SidebarIconButton(help: "New Kimi Code Session in Group") {
                            onNewKimiTab(group)
                        } label: {
                            KimiIcon(size: 12)
                        }
                        .opacity(alwaysShowActions || isHeaderHovered ? 1 : 0)
                        .allowsHitTesting(alwaysShowActions || isHeaderHovered)
                    }
                    if showPi {
                        SidebarIconButton(help: "New Pi Session in Group") {
                            onNewPiTab(group)
                        } label: {
                            PiIcon(size: 12)
                        }
                        .opacity(alwaysShowActions || isHeaderHovered ? 1 : 0)
                        .allowsHitTesting(alwaysShowActions || isHeaderHovered)
                    }
                    /// Always a new terminal from here, never a migration: a header
                    /// stands for several terminals, so there is no single tab a
                    /// switch could be about. See `WorktreeEntryRule`.
                    WorktreeEntryButton(
                        entry: .groupHeader,
                        isEnabled: showWorktree,
                        /// A project group's own root wins over the repository a tab
                        /// in it happens to sit in, and that is why this is nil when
                        /// the group declares one. The group stands for the whole
                        /// folder — `~/Projects/Aurora` and its six repositories —
                        /// so offering only the one repository the first tab is in
                        /// would answer a question nobody asked from a group header.
                        repoRoot: group.projectRoot == nil ? representativeTab?.repoRoot : nil,
                        scanRoot: group.projectRoot ?? representativeTab?.pwd,
                        currentPath: representativeTab?.pwd ?? group.projectRoot,
                        isIdle: true,
                        hasLiveAgent: false,
                        editorCenter: editorCenter,
                        terminalPwds: tabManager.models.compactMap(\.pwd),
                        onMigrate: { _, _ in },
                        onNewTerminal: { path in onNewWorktreeTabInGroup(group, path) },
                        /// No grouping item from inside a group's own header — the
                        /// group is already here.
                        onCreateGroup: nil,
                        onViewFile: { path in editorCenter.open(URL(fileURLWithPath: path)) },
                        isRevealed: alwaysShowActions || isHeaderHovered)
                    if showNewTerminal {
                        SidebarIconButton(help: "New Terminal in Group") {
                            onNewTab(group)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .opacity(alwaysShowActions || isHeaderHovered ? 1 : 0)
                        .allowsHitTesting(alwaysShowActions || isHeaderHovered)
                    }
        }
    }

    /// The count, which is always there when the reader has it switched on.
    private var countSlot: some View {
        Group {
            if showCount {
                SidebarCountBadge(count: tabs.count)
            }
        }
    }

    /// What the header paints itself with, named once so the fade under the
    /// floating buttons can repeat it exactly.
    private var headerSurface: AnyShapeStyle {
        AnyShapeStyle((accent ?? .clear).opacity(0.18))
    }

    private var header: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 6) {
                SidebarIconButton(
                    help: collapsed ? "Expand Group" : "Collapse Group"
                ) {
                    store.toggleCollapsed(group.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                }

                SidebarGroupIcon(icon: group.icon)
                    .foregroundStyle(accent ?? Color.secondary)

                /// The name outranks everything to its right.
                ///
                /// Without this the group's name is what a narrow sidebar drops
                /// first: `Spacer` and the hover-only buttons are happy at their
                /// ideal size, so SwiftUI takes the space out of the only view
                /// willing to give it, and the row ends up as an icon with no
                /// label at all. Truncating a long name is the correct way to
                /// run out of room; a row you cannot identify is not.
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name)
                        .font(palette.font(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let details = group.details, !details.isEmpty {
                        Text(details)
                            .font(palette.font(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .layoutPriority(1)

                if collapsed {
                    GroupStatusRollup(tabs: tabs, accent: accent)
                }

                Spacer(minLength: 0)

                if alwaysShowActions { headerActions }

                countSlot.hidden()
            }
            .fadingUnderFloatingActions(
                width: alwaysShowActions ? 0 : clusterWidth,
                isRevealed: !alwaysShowActions && isHeaderHovered)

            HStack(spacing: 6) {
                if !alwaysShowActions { headerActions }

                countSlot
            }
            .measuringFloatingActions()
        }
        .onPreferenceChange(FloatingActionsWidthKey.self) { clusterWidth = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(headerSurface)
        .contentShape(Rectangle())
        .onTapGesture {
            store.toggleCollapsed(group.id)
        }
        .onHover { isHeaderHovered = $0 }
        .onDrag {
            NSItemProvider(object: "group:\(group.id.uuidString)" as NSString)
        }
        .contextMenu { groupMenu }
        /// Which repositories the group's root holds, asked for once per
        /// launch and cached by `GitCenter`. It is asked from here rather
        /// than from the worktree button because the button draws nothing
        /// while the answer is "none", and a view that is not on screen
        /// cannot ask the question that would put it there.
        .task(id: group.projectRoot) {
            guard let root = group.projectRoot, !root.isEmpty else { return }
            GitCenter.shared.requestWorkspaceRepos(root: root)
        }
    }

    /// The header's menu.
    ///
    /// Glyphs in the same vocabulary the tab row's menu uses — `plus` is the
    /// header's own New Terminal button, and an edit is a pencil wherever one
    /// is offered. The six agent items share one, because an agent's mark is
    /// a view this app draws rather than a symbol AppKit can put beside a
    /// menu title, and six different symbols for one action would be six
    /// guesses at which agent each stood for.
    @ViewBuilder
    private var groupMenu: some View {
        Button { onNewTab(group) } label: {
            Label("New Terminal in Group", systemImage: "plus")
        }
        Button { onNewClaudeTab(group) } label: {
            Label("New Claude Session in Group", systemImage: "sparkles")
        }
        Button { onNewCodexTab(group) } label: {
            Label("New Codex Session in Group", systemImage: "sparkles")
        }
        Button { onNewOpenCodeTab(group) } label: {
            Label("New OpenCode Session in Group", systemImage: "sparkles")
        }
        Button { onNewAntigravityTab(group) } label: {
            Label("New Antigravity Session in Group", systemImage: "sparkles")
        }
        Button { onNewKimiTab(group) } label: {
            Label("New Kimi Code Session in Group", systemImage: "sparkles")
        }
        Button { onNewPiTab(group) } label: {
            Label("New Pi Session in Group", systemImage: "sparkles")
        }

        Divider()

        Button { isEditing = true } label: {
            Label("Edit Group…", systemImage: "pencil")
        }

        colorMenu

        Divider()

        Button {
            store.toggleCollapsed(group.id)
        } label: {
            Label(
                collapsed ? "Expand" : "Collapse",
                systemImage: collapsed ? "chevron.down" : "chevron.up"
            )
        }

        Divider()

        Button(role: .destructive) {
            store.deleteGroup(group.id)
        } label: {
            Label("Delete Group", systemImage: "trash")
        }

        /// Hidden rather than disabled on an empty group: with no terminals
        /// the two items would say the same thing, and the one a reader has
        /// to think about should only be there when it means something.
        if !tabs.isEmpty {
            Button(role: .destructive) {
                pendingClose = PendingGroupClose(
                    tabs: tabs,
                    runningProcesses: runningProcessCount
                )
            } label: {
                Label("\(deleteWithTerminalsTitle)\u{2026}", systemImage: "xmark.bin")
            }
        }
    }

    /// The colour picker, its own property because the two grids of swatches
    /// push the menu past what the SwiftUI type checker will solve in one
    /// body.
    @ViewBuilder
    private var colorMenu: some View {
        Menu {
            Section("General") {
                ForEach(TerminalTabColor.allCases, id: \.self) { color in
                    Button {
                        store.update(group.id) {
                            $0.color = color
                            $0.colorHex = nil
                        }
                    } label: {
                        HStack {
                            Image(nsImage: color.menuSwatch)
                            Text(color.localizedName)
                            if group.color == color && group.colorHex == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            if !ThemePalette.shared.colors.isEmpty {
                Section("Theme") {
                    ForEach(Array(ThemePalette.shared.colors.enumerated()), id: \.offset) { index, nsColor in
                        let hex = nsColor.hexString ?? ""
                        Button {
                            store.update(group.id) { $0.colorHex = hex }
                        } label: {
                            HStack {
                                Image(nsImage: TerminalTabColor.menuSwatch(for: nsColor))
                                Text(ThemePalette.ansiNames[index])
                                if group.colorHex == hex {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
    }

    /// How many of this header's terminals still have something running,
    /// asked of the core the way every other batch close in the app asks it
    /// (`TerminalController.closeOtherTabs`).
    private var runningProcessCount: Int {
        tabs.filter { tab in
            guard let controller = tab.window?.windowController as? BaseTerminalController
            else { return false }
            return controller.surfaceTree.contains { $0.needsConfirmQuit }
        }.count
    }

    /// Closes every terminal this header draws, then drops the group.
    ///
    /// Each tab leaves through `TerminalController.closeTabImmediately`, the
    /// step `Close Other Tabs` and `Close Tabs to the Right` both end at, so a
    /// tab that is the last one in its window still turns into a window close
    /// and each one registers its own restore. The running-process question is
    /// asked once, above, for the whole set — the shape every batch close in
    /// this app already has. Per-tab sheets were the alternative and they are
    /// worse here: a stack of four alerts on four tabs is not a safety net a
    /// reader reads, and the count they agreed to would stop being the count
    /// that goes.
    ///
    /// Only these surfaces are cleared from the store. A member of the same
    /// group living in another window is not drawn here and is not closed, so
    /// it keeps its name, icon and color and only loses the group.
    private func deleteGroupAndCloseTerminals(_ pending: PendingGroupClose) {
        let controllers = pending.tabs.compactMap {
            $0.window?.windowController as? TerminalController
        }
        WindowBreadcrumbs.note(
            "sidebar delete group with terminals: group=\(group.name) "
            + "tabs=\(pending.tabs.count) controllers=\(controllers.count)")

        store.deleteGroup(group.id, closingTabs: pending.tabs.compactMap(\.surfaceId))

        /// Read before the first close, while there is still a window to read
        /// it from, and grouped so one undo answers for the whole batch
        /// instead of giving the tabs back one press at a time.
        let undoManager = controllers.first?.undoManager
        undoManager?.beginUndoGrouping()
        for controller in controllers {
            controller.closeTabImmediately(registerRedo: false)
        }
        undoManager?.setActionName("Close Terminals in Group")
        undoManager?.endUndoGrouping()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let targetGroupId = group.id
        dragState.clear()
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String else { return }
            Task { @MainActor in
                switch SidebarDragPayload(string) {
                case .group(let movedId):
                    store.moveGroup(movedId, before: targetGroupId)
                case .tab(let surfaceId):
                    store.assign(surfaceId: surfaceId, to: targetGroupId)
                case nil:
                    break
                }
            }
        }
        return true
    }
}

/// Rolls every tab's agent state into one glyph on the group header,
/// shown only while the group is collapsed — expanded, each tab already
/// carries its own indicator (`SidebarTabRow.statusIndicator`), so this
/// would just be a second copy of the same thing.
///
/// `SidebarGroupSection` holds `tabs` as a plain, non-observed array —
/// membership changes re-render it, but an existing tab's own `agentState`
/// flipping doesn't, the same way it doesn't for the list overall (each
/// row observes its own model directly instead). This does the same thing
/// at the group level: it subscribes to every tab's publisher itself
/// rather than trusting `tabs` to change identity when only their
/// contents do.
/// The mark for a tab that is compacting: the glyph for the operation, kept
/// breathing so it cannot be read as a tab that has stopped.
///
/// A view of its own rather than a branch in `statusIndicator`, because the
/// animation is the reason it exists and a repeating animation declared inside
/// a `switch` would be built for every row that reaches that `switch`. Here it
/// starts when a compacting row appears and stops with it.
private struct CompactingMark: View {
    let color: Color

    @State private var isDim = false

    var body: some View {
        Image(systemName: "rectangle.compress.vertical")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .opacity(isDim ? 0.35 : 1)
            .help("Compacting the conversation")
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) {
                    isDim = true
                }
            }
    }
}

private struct GroupStatusRollup: View {
    let tabs: [SidebarTabModel]
    let accent: Color?

    @ObservedObject private var themePalette: ThemePalette = .shared
    @State private var tick = 0

    var body: some View {
        content
            .font(.system(size: 10))
            .onReceive(Publishers.MergeMany(tabs.map { $0.objectWillChange })) { _ in
                tick &+= 1
            }
    }

    @ViewBuilder
    private var content: some View {
        if tabs.contains(where: { $0.agentState == .failed }) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help("A terminal in this group failed")
        } else if tabs.contains(where: { $0.agentState == .denied }) {
            Image(systemName: "octagon.fill")
                .foregroundStyle(.orange)
                .help("An action was denied in this group")
        } else if tabs.contains(where: { $0.agentState == .awaiting }) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(themePalette.magenta ?? .purple)
                .help("A terminal in this group needs your input")
        } else if tabs.contains(where: { $0.needsAttention }) {
            Circle()
                .fill(accent ?? .accentColor)
                .frame(width: 6, height: 6)
                .help("A terminal in this group needs attention")
        } else if tabs.contains(where: { $0.agentState == .compacting }) {
            CompactingMark(color: themePalette.yellow ?? .orange)
                .help("A terminal in this group is compacting its conversation")
        } else if tabs.contains(where: { $0.agentState == .working }) {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
                .help("A terminal in this group is working")
        } else if tabs.contains(where: { $0.agentState == .done }) {
            Circle()
                .fill(accent ?? Color.accentColor)
                .frame(width: 6, height: 6)
                .help("A terminal in this group has a response ready")
        }
    }
}

/// The two things draggable in the sidebar, encoded as plain strings:
/// a raw surface UUID for tabs, `group:<uuid>` for group headers.
private enum SidebarDragPayload {
    case tab(UUID)
    case group(UUID)

    init?(_ string: String) {
        if string.hasPrefix("group:") {
            guard let id = UUID(uuidString: String(string.dropFirst("group:".count)))
            else { return nil }
            self = .group(id)
        } else if let id = UUID(uuidString: string) {
            self = .tab(id)
        } else {
            return nil
        }
    }
}

/// Insert-between drop handling for a tab row: the drop position within
/// the row picks before/after, and the drop adopts the row's group.
private struct TabRowDropDelegate: DropDelegate {
    let target: SidebarTabModel
    let groupId: UUID?
    let store: SidebarGroupStore
    let dragState: SidebarDragState

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragState.mark(row: target.id, after: info.location.y > 18)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dragState.clear(row: target.id)
    }

    func performDrop(info: DropInfo) -> Bool {
        let after = dragState.target?.after ?? true
        dragState.clear()

        guard let provider = info.itemProviders(for: [.plainText]).first,
              let targetId = target.surfaceId
        else { return false }

        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String else { return }
            Task { @MainActor in
                switch SidebarDragPayload(string) {
                case .tab(let surfaceId):
                    store.insert(
                        surfaceId: surfaceId,
                        near: targetId,
                        after: after,
                        groupId: groupId
                    )
                case .group(let movedId):
                    if let groupId {
                        store.moveGroup(movedId, before: groupId)
                    } else {
                        store.moveGroup(movedId, toIndex: store.groups.count)
                    }
                case nil:
                    break
                }
            }
        }
        return true
    }
}

/// One tab row: title + working directory, click to activate.
private struct SidebarTabRow: View {
    @ObservedObject var tab: SidebarTabModel
    let groupId: UUID?
    let tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore
    @ObservedObject var dragState: SidebarDragState

    /// The editor of the window drawing this row — a fallback only. What
    /// this row's actions need is `tabEditorCenter`.
    @ObservedObject var editorCenter: EditorCenter

    /// Opens a terminal in a directory — the worktree panel's own callback,
    /// reused so a new terminal started from a row lands the same way one
    /// started from the panel does.
    let onNewWorktreeTab: (String, UUID?) -> Void
    @ObservedObject private var themePalette: ThemePalette = .shared
    @ObservedObject private var planCenter: ClaudePlanCenter = .shared

    /// Observed so a tab's file icon follows a theme change live, the same
    /// as the explorer's and the Git panel's.
    @ObservedObject private var icons: FileIconProvider = .shared

    @State private var isHovered = false

    /// How wide this row's whole trailing cluster is — buttons, status mark
    /// and close button — measured by the layout that draws it.
    @State private var clusterWidth: CGFloat = 0
    @State private var isCreatingGroup = false
    @State private var isCustomizing = false
    @State private var groupingWorktree: GitWorktree?

    /// The plan whose file the reader has asked to delete, held while the
    /// confirmation is up so the sheet can name it.
    @State private var pendingPlanDelete: ClaudePlanIndex.Plan?

    @AppStorage("SidebarShowDirectory") private var showDirectory = true
    @AppStorage("SidebarShowGitBranch") private var showGitBranch = true
    @AppStorage("SidebarShowGitStatus") private var showGitStatus = true
    @AppStorage("SidebarShowPullRequest") private var showPullRequest = true
    @AppStorage("SidebarShowDevServer") private var showDevServer = true
    @AppStorage("SidebarShowPlan") private var showPlan = true
    @AppStorage("SidebarTabDensity") private var density = "default"

    /// Which agents this row offers to start, mirroring the keys the sidebar
    /// header and the group header already use for their own buttons.
    @AppStorage(AgentButtonDefaults.key(.tabRow, .claude)) private var showClaudeAction = AgentButtonDefaults.isShown(.claude)
    @AppStorage(AgentButtonDefaults.key(.tabRow, .codex)) private var showCodexAction = AgentButtonDefaults.isShown(.codex)
    @AppStorage(AgentButtonDefaults.key(.tabRow, .opencode)) private var showOpenCodeAction = AgentButtonDefaults.isShown(.opencode)
    @AppStorage(AgentButtonDefaults.key(.tabRow, .antigravity)) private var showAntigravityAction = AgentButtonDefaults.isShown(.antigravity)
    @AppStorage(AgentButtonDefaults.key(.tabRow, .kimi)) private var showKimiAction = AgentButtonDefaults.isShown(.kimi)
    @AppStorage(AgentButtonDefaults.key(.tabRow, .pi)) private var showPiAction = AgentButtonDefaults.isShown(.pi)
    @AppStorage("SidebarTabShowWorktree") private var showWorktreeAction = true
    @AppStorage("SidebarTabAlwaysShowActions") private var alwaysShowActions = false

    private var isCompact: Bool { density == "compact" }

    /// The editor belonging to the terminal this row stands for.
    ///
    /// Not the one that happens to be drawing the sidebar. Every tab is its
    /// own `TerminalController` with its own `EditorCenter`, and the sidebar
    /// lists all of them — so a row for tab A, rendered inside tab B's
    /// sidebar, was computing tab A's worktree switch against tab B's open
    /// documents. With B's editor empty the plan came back empty, the
    /// confirm never appeared, and A's unsaved file was carried across
    /// without a word. Which is the exact promise this whole flow makes and
    /// the exact way to break it.
    private var tabEditorCenter: EditorCenter {
        (tab.window?.windowController as? TerminalController)?.editorCenter ?? editorCenter
    }

    private var insertAfter: Bool? {
        guard dragState.target?.row == tab.id else { return nil }
        return dragState.target?.after
    }

    /// The agent buttons this row draws, decided by `TabRowAgentActions` — a
    /// tab already running one gets none, because these type into its shell.
    private var agentActions: [CodingAgent] {
        var shown: Set<CodingAgent> = []
        if showClaudeAction { shown.insert(.claude) }
        if showCodexAction { shown.insert(.codex) }
        if showOpenCodeAction { shown.insert(.opencode) }
        if showAntigravityAction { shown.insert(.antigravity) }
        if showKimiAction { shown.insert(.kimi) }
        if showPiAction { shown.insert(.pi) }

        return TabRowAgentActions.agents(shown: shown, liveAgent: tab.liveAgent)
    }

    /// Each agent's own mark, at the size the group header uses. Separate
    /// types rather than one image name, so this is a switch and not a lookup.
    @ViewBuilder
    private func agentIcon(_ agent: CodingAgent) -> some View {
        switch agent {
        case .claude: ClaudeIcon(size: 11)
        case .codex: CodexIcon(size: 11)
        case .opencode: OpenCodeIcon(size: 11)
        case .antigravity: AntigravityIcon(size: 11)
        case .kimi: KimiIcon(size: 11)
        case .pi: PiIcon(size: 11)
        }
    }

    private var override: SidebarGroupStore.TabOverride? {
        tab.surfaceId.flatMap { store.tabOverrides[$0] }
    }

    private var displayTitle: String {
        TerminalDisplayName.resolve(custom: override?.name, terminalTitle: tab.title)
    }

    /// The program holding a file open, for the tabs that were opened for
    /// one.
    ///
    /// Read from the terminal's foreground process rather than from the
    /// editor we asked for. `$EDITOR` is resolved by the user's shell, so
    /// the command sent was `${EDITOR:-vim}` and only the shell knows what
    /// that became — and this way the chip is right for a `nano` opened by
    /// hand, and goes away by itself the moment the editor is quit.
    private var editorName: String? {
        guard let file = override?.fileName, !file.isEmpty else { return nil }
        guard let name = tab.foregroundName, !TerminalIdleCheck.isShell(name) else { return nil }
        return name
    }

    /// The buttons that come and go with the hover: everything on this row
    /// that types into the tab's shell, and the worktree entry beside them.
    ///
    /// Held here rather than written into the row so the layout below can
    /// place the same cluster in two different places — in the row when the
    /// reader has pinned it, over the row when they have not.
    ///
    /// An `HStack` of its own rather than a bare group, so that the spacing
    /// between these buttons is stated here and does not depend on how the
    /// caller's builder flattens them.
    private var rowActions: some View {
        HStack(spacing: 6) {
            /// Before the agent buttons, and gone under the same conditions
            /// they are: all of these type into the tab's shell.
            WorktreeEntryButton(
                entry: .tabRow,
                isEnabled: showWorktreeAction,
                repoRoot: tab.repoRoot,
                currentPath: tab.pwd,
                isIdle: TerminalIdleCheck.isIdle(foregroundPID: tab.foregroundPID),
                hasLiveAgent: tab.liveAgent != nil,
                editorCenter: tabEditorCenter,
                terminalPwds: tabManager.models.compactMap(\.pwd),
                onMigrate: { worktree, plan in
                    tabManager.select(tab)
                    WorktreeMigrate.perform(
                        to: worktree, plan: plan, tab: tab, editorCenter: tabEditorCenter)
                },
                /// This row's own group, so a worktree opened from a
                /// terminal inside a group lands inside it.
                onNewTerminal: { path in onNewWorktreeTab(path, groupId) },
                onCreateGroup: { worktree in groupingWorktree = worktree },
                onViewFile: { path in tabEditorCenter.open(URL(fileURLWithPath: path)) },
                isRevealed: alwaysShowActions || isHovered)
            ForEach(agentActions, id: \.self) { agent in
                SidebarIconButton(help: "Start \(agent.displayName) in This Tab") {
                    tabManager.select(tab)
                    AgentLauncher.start(agent, in: tab)
                } label: {
                    agentIcon(agent)
                }
                .opacity(alwaysShowActions || isHovered ? 1 : 0)
                .allowsHitTesting(alwaysShowActions || isHovered)
            }
        }
    }

    /// The one control at the trailing end that is always there: what the tab
    /// is doing, and — on hover — the close button in its place.
    private var statusSlot: some View {
        ZStack {
            statusIndicator
                .opacity(isHovered ? 0 : 1)

            SidebarIconButton(help: "Close Terminal") {
                WindowBreadcrumbs.note(
                    "sidebar close button: window=\(tab.window?.windowNumber ?? -1)")
                tab.window?.performClose(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .frame(width: 24, height: 22)
    }

    /// The row: its content across the full width, and its buttons over the
    /// top of that content unless the reader asked for them to be pinned.
    ///
    /// The buttons used to sit in this `HStack` in both cases, drawn at
    /// `opacity(0)` when the hover was elsewhere — invisible, and still
    /// holding their place. A row therefore reserved room for a worktree
    /// button and up to six agent marks it was not drawing, the title and the
    /// chips were laid out in what was left, and a folder chip that fits the
    /// row wrapped onto a second line to make space for nothing. Pinned, the
    /// buttons are content and sharing the width is right; unpinned they are
    /// an overlay, and take nothing.
    ///
    /// `statusSlot` is in both stacks on purpose: the visible one rides with
    /// the buttons so it is never covered by them, and a hidden copy holds
    /// its width in the row. That is what keeps the floating cluster clear of
    /// it without anybody writing its width down as a number.
    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 6) {
                /// The tab's own colour, opening the row rather than sitting
                /// between the icon and the title.
                ///
                /// It was a 6pt dot there, which is the same shape and the same
                /// size as the unread dot `statusIndicator` draws for
                /// `needsAttention` — one row carrying two round marks that mean
                /// unrelated things, and the colour one landed where a badge
                /// belongs. A bar at the leading edge cannot be read as
                /// notification: nothing else on the row is a bar. It stays a row
                /// element and not a border on `rowBackground`, so the icon and
                /// the title move over for it.
                ///
                /// Left inside the same `if let` the dot used, because that is
                /// what keeps an uncoloured tab laying out exactly as before: a
                /// view that is absent adds no `HStack` spacing, while a
                /// zero-width placeholder would still push the icon over by 6.
                if let accent = override?.accentColor {
                    /// As tall as the row, less a short inset at each end, rather
                    /// than as tall as the icon. At the icon's height it read as
                    /// a mark beside the icon; running most of the row it reads
                    /// as the row's own label, which is what it is. The inset is
                    /// what keeps it from touching the row's rounded background.
                    ///
                    /// `maxHeight` rather than a number: the row grows with the
                    /// density setting and with the metadata under the title, and
                    /// a fixed height would come loose from it. The stack's height
                    /// is set by its other children, so this takes it without
                    /// being able to stretch the row.
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accent)
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 3)
                }

                // A tab opened for a file wears that file's icon, from whichever
                // icon theme is active — the same artwork the explorer and the
                // Git panel show it with, so the three read as one thing. A hand
                // -picked icon still wins: it was chosen on purpose.
                if let icon = override?.icon, !icon.isEmpty {
                    SidebarGroupIcon(icon: icon, size: 13)
                        .foregroundStyle(.secondary)
                } else if let file = override?.fileName, !file.isEmpty {
                    FileIconView(icon: icons.icon(forFile: file), size: iconBoxHeight)
                }

                VStack(alignment: .leading, spacing: isCompact ? 2 : 4) {
                    Text(displayTitle)
                        .font(themePalette.font(
                            size: isCompact ? 11 : 12,
                            weight: tab.isSelected ? .semibold : .regular
                        ))
                        .lineLimit(1)

                    WrapLayout(horizontalSpacing: 4, verticalSpacing: 3) {
                        if let editor = editorName {
                            metaChip(icon: "square.and.pencil", text: editor)
                        }

                        /// The project for a worktree tab, the folder for every
                        /// other: a worktree's folder is `<repo>-<branch>` and
                        /// would say the branch twice.
                        if showDirectory, let dir = tab.worktreeRepo ?? tab.directoryName {
                            metaChip(text: dir)
                        }

                        if showGitBranch, let branch = tab.gitBranch {
                            /// The glyph carries the signal, not the colour:
                            /// colour alone is ambiguous — the accent wash is
                            /// used elsewhere on this row — while a branch
                            /// network says "worktree" and nothing else.
                            metaChip(
                                gitIcon: !tab.isInManagedWorktree,
                                worktreeIcon: tab.isInManagedWorktree,
                                text: branch,
                                dirty: showGitStatus && tab.isDirty == true
                            )
                        }

                        /// Before the pull request and the dev server, because it
                        /// is the only one of the three that is asking for
                        /// something. A repository mid-merge cannot be committed
                        /// to, pushed from or branched off until it is finished,
                        /// and a reader who has forgotten a half-done merge in
                        /// another terminal finds out from git at the moment it
                        /// refuses them.
                        ///
                        /// Not behind a setting either, unlike every chip around
                        /// it. Those say something about a repository that is
                        /// working; this says it is stuck, and a reader who
                        /// switched it off would be switching off the one chip
                        /// they cannot infer from anywhere else on the row.
                        if let conflicts = tab.conflicts, conflicts > 0 {
                            conflictChip(count: conflicts)
                        }

                        if showPullRequest, let prNumber = tab.prNumber {
                            prChip(number: prNumber)
                        }

                        if showDevServer, let port = tab.devServerPort {
                            devServerChip(port: port)
                        }

                        if let plan = visiblePlan {
                            planChip(plan: plan)
                        }

                        // Reserve the metadata line even while pwd/branch
                        // haven't arrived yet so row heights never shift.
                        if showDirectory || showGitBranch {
                            Text(" ").font(.system(size: 9))
                        }
                    }
                    /// A floor, not a ceiling: long branch and folder names wrap
                    /// onto further lines instead of ellipsizing away the exact
                    /// part that tells two refactor branches apart.
                    .frame(minHeight: isCompact ? 14 : 18)
                }

                Spacer(minLength: 0)

                if alwaysShowActions { rowActions }

                statusSlot.hidden()
            }
            /// The content stops where the buttons start, and only while they
            /// are on screen. Plus the stack's own spacing, which is the gap
            /// between the cluster and the status slot the content must also
            /// stay out of.
            .fadingUnderFloatingActions(
                width: alwaysShowActions ? 0 : clusterWidth,
                isRevealed: !alwaysShowActions && isHovered)

            HStack(spacing: 6) {
                if !alwaysShowActions { rowActions }

                statusSlot
            }
            /// The whole cluster, status slot included, because that is the
            /// span the content has to be out from under. Measuring the
            /// buttons alone left the fade running beneath the first of them.
            .measuringFloatingActions()
        }
        .onPreferenceChange(FloatingActionsWidthKey.self) { clusterWidth = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, isCompact ? 5 : 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            tabManager.select(tab)
            if let surfaceId = tab.surfaceId {
                TabStateCenter.shared.clearDone(surfaceId: surfaceId)
            }
        }
        .onChange(of: tab.isSelected) { selected in
            guard selected, let surfaceId = tab.surfaceId else { return }
            TabStateCenter.shared.clearDone(surfaceId: surfaceId)
        }
        .onHover { isHovered = $0 }
        .onDrag {
            NSItemProvider(object: (tab.surfaceId?.uuidString ?? "") as NSString)
        }
        .onDrop(
            of: [.plainText],
            delegate: TabRowDropDelegate(
                target: tab,
                groupId: groupId,
                store: store,
                dragState: dragState
            )
        )
        .overlay(alignment: .top) {
            if insertAfter == false {
                Rectangle().fill(themePalette.accent ?? .accentColor).frame(height: 2)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if insertAfter == true {
                Rectangle().fill(themePalette.accent ?? .accentColor).frame(height: 2)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.1), value: insertAfter)
        .contextMenu { tabMenu }
        .sheet(isPresented: $isCreatingGroup) {
            SidebarGroupEditor(
                group: nil,
                store: store,
                assignSurfaceId: tab.surfaceId
            )
        }
        /// Every terminal working in that worktree, not just this one: the
        /// gesture is about the worktree, and a group holding one of its
        /// three terminals would be a group that means something narrower
        /// than what was pointed at.
        .sheet(item: $groupingWorktree) { worktree in
            SidebarGroupEditor(
                group: nil,
                store: store,
                assignSurfaceIds: tabManager.models
                    .filter { GitWorktreeMembership.contains(pwd: $0.pwd, root: worktree.path) }
                    .compactMap(\.surfaceId),
                initialName: worktree.branch
                    ?? (worktree.path as NSString).lastPathComponent
            )
        }
        .sheet(isPresented: $isCustomizing) {
            if let surfaceId = tab.surfaceId {
                SidebarTabEditor(
                    surfaceId: surfaceId,
                    currentTitle: tab.title,
                    store: store
                )
            }
        }
        .confirmationDialog(
            "Delete this plan?",
            isPresented: Binding(
                get: { pendingPlanDelete != nil },
                set: { if !$0 { pendingPlanDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            planDeleteButtons
        } message: {
            Text(planDeleteMessage)
        }
    }

    /// Trailing status: spinner while the agent works, a raised hand
    /// while it waits for input, an accent dot when a response is ready
    /// (cleared on selection), a red triangle when the turn failed, an
    /// orange stop sign when an action was denied, and the bell attention
    /// dot otherwise.
    @ViewBuilder
    private var statusIndicator: some View {
        switch tab.agentState {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case .awaiting:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11))
                .foregroundStyle(themePalette.magenta ?? .purple)
                .help("Waiting for your input")
        case .done:
            Circle()
                .fill(themePalette.accent ?? .accentColor)
                .frame(width: 8, height: 8)
        case .compacting:
            CompactingMark(color: themePalette.yellow ?? .orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .help("The agent turn failed")
        case .denied:
            Image(systemName: "octagon.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .help("An action was denied")
        case .ended, nil:
            if tab.needsAttention {
                Circle()
                    .fill(themePalette.accent ?? .accentColor)
                    .frame(width: 6, height: 6)
            }
        }
    }

    /// The box the row opens with: the file icon's frame, and with it the
    /// height of the colour bar that precedes the icon.
    ///
    /// Measured from `FileIconView`, which frames itself square at the size
    /// it is given and is the tallest of the things that can start a row —
    /// rather than picked to look right, which is how the bar would drift out
    /// of line the next time the icon is resized. Density is not part of it:
    /// the icon is the one piece of the row compact leaves alone, so both
    /// densities center the same bar against the same icon.
    private var iconBoxHeight: CGFloat { 14 }

    /// The shared line box every chip element is centered within.
    private var chipLineHeight: CGFloat { 11 }

    /// The clickable Plan tag: opens the plan the agent wrote for this
    /// project.
    ///
    /// Attributed to the *project*, not to this terminal — nothing in a plan
    /// file says which window wrote it, and the only link that exists runs
    /// through the session transcript to a working directory. So every
    /// terminal in the project shows it, which is also true to what a plan
    /// is: it belongs to the work.
    private func planChip(plan: ClaudePlanIndex.Plan) -> some View {
        Button {
            openPlan(plan)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "text.rectangle.page")
                    // A size, not a text style: the glyph inherited the row's
                    // font metrics and came out taller than the chip.
                    .font(.system(size: isCompact ? 7 : 8))
                    .imageScale(.small)
                Text("Plan")
                    .font(.system(size: isCompact ? 9 : 10, weight: .medium))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.18))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help(plan.title)
        .contextMenu { planMenu(plan: plan) }
    }

    /// The plan this row is wearing, if it is wearing one.
    ///
    /// One question asked in one place, because the tag and the menu that
    /// clears it must not disagree: a menu offering to hide a tag that is not
    /// on screen would write a record the reader cannot see the effect of.
    private var visiblePlan: ClaudePlanIndex.Plan? {
        guard showPlan, ClaudePlanIndex.tagIsVisible(liveAgent: tab.liveAgent) else { return nil }
        return planCenter.plan(forTerminalAt: tab.pwd)
    }

    /// What a reader can do about a plan besides open it.
    ///
    /// Offered from the tag and from the row's own menu. The tag is where a
    /// leftover is noticed, and it is eleven points tall — a reader who wants
    /// the row's menu should not have to aim around it. The row's menu is
    /// also the way in that always works: the row fades its content out
    /// under the hover buttons with a mask, and a mask takes the clicks with
    /// the pixels, so a tag that ends up beneath the cluster cannot be
    /// right-clicked itself.
    ///
    /// Hiding is per plan and not per row, so both items say "Plan" and
    /// neither says "this tab": the same plan wears the same tag on every
    /// terminal in its project, and both of these clear all of them.
    @ViewBuilder
    private func planMenu(plan: ClaudePlanIndex.Plan) -> some View {
        Button {
            planCenter.hide(plan)
        } label: {
            Label("Hide Plan", systemImage: "eye.slash")
        }

        Button(role: .destructive) {
            pendingPlanDelete = plan
        } label: {
            Label("Delete Plan…", systemImage: "trash")
        }
    }

    /// Names the plan, where it lives and that it does not come back.
    ///
    /// The file is in the reader's home directory and nothing in this app
    /// puts it back — the shape `GitRepoView` uses to warn about a commit,
    /// with the thing being acted on quoted so the sentence is about one
    /// plan rather than about plans.
    private var planDeleteMessage: String {
        guard let plan = pendingPlanDelete else { return "" }
        return "“\(plan.title)” will be removed from ~/.claude/plans. "
            + "This cannot be undone."
    }

    /// Cancel takes the cancel role and the default action, for the reason
    /// the group header's close sheet gives: Return must not be the key that
    /// deletes a file.
    @ViewBuilder
    private var planDeleteButtons: some View {
        Button("Delete Plan", role: .destructive) {
            if let plan = pendingPlanDelete { planCenter.delete(plan) }
            pendingPlanDelete = nil
        }
        Button("Cancel", role: .cancel) { pendingPlanDelete = nil }
            .keyboardShortcut(.defaultAction)
    }

    /// Opens a plan through the same opener a file in the panels uses, so the
    /// Settings choice means the same thing everywhere.
    private func openPlan(_ plan: ClaudePlanIndex.Plan) {
        guard let controller = tab.window?.windowController as? TerminalController else { return }
        controller.openClickedPath(URL(fileURLWithPath: plan.path), line: nil as Int?, column: nil)
    }

    /// A small rounded tag for row metadata (directory, git branch).
    private func metaChip(
        icon: String? = nil,
        gitIcon: Bool = false,
        worktreeIcon: Bool = false,
        text: String,
        dirty: Bool = false
    ) -> some View {
        // Every element is centered in one fixed-height line box: the symbol's
        // layout box is taller than the text's, so letting each size itself
        // pushes the label and the dirty dot visibly below the icon.
        HStack(alignment: .center, spacing: 3) {
            if worktreeIcon {
                /// The branch mark swapped for the worktree mark, rather
                /// than a second element on a row that already has enough:
                /// folder plus branch does not distinguish a worktree,
                /// because the main checkout shows both too.
                WorktreeIcon(size: 9)
                    .frame(height: chipLineHeight)
            } else if gitIcon {
                GitIcon(size: 8)
                    .frame(height: chipLineHeight)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .frame(height: chipLineHeight)
            }
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: chipLineHeight)
            if dirty {
                Circle()
                    .fill(.yellow)
                    .frame(width: 4, height: 4)
                    .frame(height: chipLineHeight)
            }
        }
        .font(themePalette.font(size: 9))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.6))
        )
        .help(worktreeIcon
            ? (dirty ? "Worktree · uncommitted changes" : "Worktree")
            : (dirty ? "Uncommitted changes" : ""))
    }

    /// The clickable PR tag: opens the branch's open pull request.
    /// How many paths this terminal's repository cannot merge.
    ///
    /// Red rather than the theme's accent, which is the one place on this row
    /// that breaks from the theme on purpose: every other chip is information,
    /// and this is a stop sign.
    ///
    /// Spelled out rather than left as a glyph and a number. Every other chip
    /// on this row is a count of something ordinary — commits behind, a pull
    /// request, a port — so a bare `2` beside them reads as one more of those.
    /// The words are what make it the one chip that is asking for something.
    private func conflictChip(count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.2.squarepath")
                .font(.system(size: 8, weight: .semibold))
            Text(verbatim: "Merge Conflicts: \(count)")
                .font(themePalette.font(size: 9, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(Color(nsColor: .systemRed))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .systemRed).opacity(0.15))
        )
        .help(count == 1
            ? "1 file has merge conflicts"
            : "\(count) files have merge conflicts")
    }

    private func prChip(number: Int) -> some View {
        Button {
            if let url = tab.prURL.flatMap(URL.init(string:)) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Text(verbatim: "#\(number)")
                .font(themePalette.font(size: 9, weight: .medium))
                .foregroundStyle(themePalette.accent ?? .accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill((themePalette.accent ?? .accentColor).opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        // Verbatim for the same reason as the badge above: a plain
        // interpolation is a LocalizedStringKey, which formats the number
        // for the locale and turns PR #1234 into "#1.234".
        .help(Text(verbatim: "Open Pull Request #\(number)"))
    }

    /// The clickable dev-server tag: opens the port this tab is serving.
    private func devServerChip(port: Int) -> some View {
        Button {
            if let url = URL(string: "http://localhost:\(port)") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .center, spacing: 3) {
                Image(systemName: "globe")
                    .font(.system(size: 8))
                    .frame(height: chipLineHeight)
                // Verbatim: a plain interpolation is a LocalizedStringKey,
                // which formats the number for the locale and turns port
                // 8899 into "8.899".
                Text(verbatim: ":\(port)")
                    .frame(height: chipLineHeight)
            }
            .font(themePalette.font(size: 9, weight: .medium))
            .foregroundStyle(Color.green)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.green.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
        // Verbatim for the same reason as the badge above: a plain
        // interpolation is a LocalizedStringKey, which formats the number
        // for the locale and turns port 8899 into "8.899".
        .help(Text(verbatim: "Open http://localhost:\(port)"))
    }

    /// Rows always carry a fill, not only when hovered or selected: over a
    /// transparent window an unfilled row leaves its text floating on the
    /// desktop with nothing to separate one terminal from the next. The
    /// tint comes from the theme so the sidebar matches the terminal.
    private var rowBackground: AnyShapeStyle {
        let accent = themePalette.primary.map { Color(nsColor: $0) }
            ?? Color(nsColor: .selectedContentBackgroundColor)

        let opacity: Double = if tab.isSelected {
            0.6
        } else if isHovered {
            0.28
        } else {
            0.12
        }

        return AnyShapeStyle(accent.opacity(opacity))
    }

    /// The row's own menu.
    ///
    /// Every item carries a glyph, in the vocabulary
    /// `FileExplorerRowCommand.icon` set: the two menus sit inches apart and
    /// share commands, so a command that appears in both looks the same in
    /// both. The group names are the exception, as the branch names in the
    /// Git panel's branch picker are — they are data, and a group's own icon
    /// may be an emoji or an agent's mark rather than a symbol AppKit can
    /// draw beside a title.
    @ViewBuilder
    private var tabMenu: some View {
        Button { isCustomizing = true } label: {
            Label("Customize Tab…", systemImage: "pencil")
        }
        .disabled(tab.surfaceId == nil)

        if let prNumber = tab.prNumber,
           let prURL = tab.prURL.flatMap(URL.init(string:)) {
            Button {
                NSWorkspace.shared.open(prURL)
            } label: {
                Label("Open Pull Request #\(prNumber)…", systemImage: "arrow.triangle.pull")
            }
        }

        if let plan = visiblePlan {
            Divider()

            planMenu(plan: plan)
        }

        Divider()

        Menu {
            ForEach(store.groups) { group in
                Button(group.name) {
                    guard let surfaceId = tab.surfaceId else { return }
                    store.assign(surfaceId: surfaceId, to: group.id)
                }
            }

            if !store.groups.isEmpty {
                Divider()
            }

            Button {
                isCreatingGroup = true
            } label: {
                Label("New Group…", systemImage: "plus.rectangle.on.rectangle")
            }

            Divider()

            Button {
                guard let surfaceId = tab.surfaceId else { return }
                store.assign(surfaceId: surfaceId, to: nil)
            } label: {
                Label("No Group", systemImage: "rectangle.on.rectangle.slash")
            }
        } label: {
            Label("Move to Group", systemImage: "rectangle.3.group")
        }

        Button(role: .destructive) {
            WindowBreadcrumbs.note(
                "sidebar context menu close: window=\(tab.window?.windowNumber ?? -1)")
            tab.window?.performClose(nil)
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }
}

/// One cell of the icon grid: hover highlight, accent fill when selected.
private struct SidebarIconCell<Mark: View>: View {
    let isSelected: Bool
    let action: () -> Void

    /// Whatever the cell offers. A symbol name cannot stand in for this any
    /// more: the agents' marks are views this app draws, not names AppKit
    /// resolves, and they keep their own colours where a symbol takes the
    /// cell's.
    @ViewBuilder let mark: () -> Mark

    @State private var isHovered = false
    @ObservedObject private var palette: ThemePalette = .shared

    var body: some View {
        Button(action: action) {
            mark()
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected
                            ? AnyShapeStyle(palette.accent ?? .accentColor)
                            : isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Visual icon picker: what was chosen lately, a grid of curated SF Symbols,
/// the agents' marks, a compact emoji field, and a door to the rest of SF
/// Symbols for anything none of that covers.
private struct SidebarIconPicker: View {
    @Binding var selection: String

    @State private var emoji: String = ""

    /// Read from the store once, in `onAppear`, and then only ever grown by a
    /// pick out of the browser. Reading it live would reorder the top row the
    /// moment a pick lands in it, and a grid that rearranges itself under the
    /// cursor is a grid you misclick.
    @State private var recents: [String] = []

    @State private var isBrowsing = false

    @FocusState private var emojiFieldFocused: Bool

    /// A full 5×7 grid of terminal-life symbols.
    private static let symbols: [String] = [
        "folder", "terminal", "flame", "bolt", "star", "heart", "hammer",
        "wrench.and.screwdriver", "gearshape", "shippingbox", "cube", "globe", "server.rack", "cloud",
        "externaldrive", "chart.bar", "doc.text", "book", "briefcase", "building.2", "cart",
        "creditcard", "testtube.2", "ladybug", "leaf", "moon.stars", "sparkles", "gamecontroller",
        "music.note", "paintbrush", "curlybraces", "cpu", "network", "lock", "bell",
    ]

    /// The rest of the agent row: symbols for the kind of work rather than
    /// for one product, so a tab running something with no mark of its own
    /// still gets a fitting icon.
    ///
    /// No robot among them because SF Symbols has none — checked, not
    /// assumed, and an unknown name draws an empty box. 🤖 through the emoji
    /// field below is the way to have one.
    private static let agentSymbols: [String] = [
        "brain", "brain.head.profile", "apple.intelligence", "wand.and.sparkles",
    ]

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 7
    )

    var body: some View {
        if !recents.isEmpty {
            sectionLabel("Recents")

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(recents, id: \.self) { icon in
                    SidebarIconCell(isSelected: selection == icon) {
                        choose(icon)
                    } mark: {
                        SidebarGroupIcon(icon: icon, size: 14)
                            .foregroundStyle(selection == icon ? .white : .primary)
                    }
                    .help(Self.tooltip(for: icon))
                }
            }
            .padding(.vertical, 4)
        }

        sectionLabel("General")

        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Self.symbols, id: \.self) { symbol in
                SidebarIconCell(isSelected: selection == symbol) {
                    choose(symbol)
                } mark: {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selection == symbol ? .white : .primary)
                }
            }

            /// The thirty-sixth cell of a seven-column grid, alone on a sixth
            /// row on purpose: the five full rows above it are the curated
            /// set, and this one is not part of it. Putting it beside the
            /// "General" heading instead would read as a heading control and
            /// lose the "and there is more where those came from" it has here,
            /// at the end of the list.
            SidebarIconCell(isSelected: false) {
                isBrowsing = true
            } mark: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .help("All Symbols…")
        }
        .padding(.vertical, 4)

        sectionLabel("AI Agents/Harness")

        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(CodingAgent.allCases, id: \.self) { agent in
                let id = SidebarIconID.id(for: agent)

                SidebarIconCell(isSelected: selection == id) {
                    choose(id)
                } mark: {
                    SidebarGroupIcon(icon: id, size: 15)
                }
                .help(agent.displayName)
            }

            ForEach(Self.agentSymbols, id: \.self) { symbol in
                SidebarIconCell(isSelected: selection == symbol) {
                    choose(symbol)
                } mark: {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selection == symbol ? .white : .primary)
                }
            }
        }
        .padding(.vertical, 4)

        LabeledContent("Emoji") {
            HStack(spacing: 6) {
                TextField("", text: $emoji, prompt: Text("🔥"))
                    .labelsHidden()
                    .focused($emojiFieldFocused)
                    .frame(width: 48)
                    .multilineTextAlignment(.center)
                    .onChange(of: emoji) { value in
                        guard let first = value.first else { return }
                        let single = String(first)
                        if emoji != single { emoji = single }
                        selection = single
                    }

                Button {
                    emojiFieldFocused = true
                    DispatchQueue.main.async {
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Choose Emoji…")
            }
        }
        .onAppear {
            /// Only an actual emoji goes in the emoji field, because that
            /// field trims to one character on edit. This used to ask the
            /// question backwards — anything absent from the curated lists
            /// and not an agent — which was true of every symbol the browser
            /// can now return, so opening the sheet on `rectangle.3.group`
            /// and touching the field would quietly turn it into `r`.
            if SidebarIconID.kind(of: selection) == .emoji { emoji = selection }

            recents = Self.visibleRecents(selection: selection)
        }
        .sheet(isPresented: $isBrowsing) {
            SidebarIconBrowser(selection: selection) { picked in
                choose(picked)

                /// Added rather than merged: a symbol out of the browser has
                /// no cell in the curated grid, so without a cell here the
                /// sheet lights up nothing at all and the only sign the pick
                /// landed is the tab itself, after Save. Added only when it
                /// is missing, so a row already holding it does not shuffle
                /// under the cursor on the way back.
                if !recents.contains(picked) {
                    recents = SidebarIconRecents.recording(picked, into: recents)
                }
            }
        }
    }

    /// One pick, whatever it was picked from.
    ///
    /// The emoji field follows the choice rather than being cleared blindly:
    /// choosing 🔥 from the Recents row has to leave the field showing 🔥, or
    /// the sheet says two different things about one selection.
    private func choose(_ icon: String) {
        selection = icon
        emoji = SidebarIconID.kind(of: icon) == .emoji ? icon : ""
    }

    /// The stored Recents row, plus the icon this tab or group already wears
    /// when nothing else in the sheet stands for it.
    ///
    /// An icon chosen from the browser last week is a symbol with no cell in
    /// the curated grid, and a row trimmed to ten may no longer hold it — so
    /// the sheet would open on it and light up nothing. Prepending it is not
    /// a lie either: it *is* the most recent choice for this tab. It goes
    /// through the same merge as a stored one, so it cannot duplicate an
    /// entry or push the row past ten.
    private static func visibleRecents(selection: String) -> [String] {
        let stored = SidebarIconRecents().icons
        guard !hasOwnCell(selection) else { return stored }
        return SidebarIconRecents.recording(selection, into: stored)
    }

    /// The Recents row mixes all three forms, so its cells cannot all be
    /// named by the string they hold: `agent:claude` is the file format, not
    /// something to show a reader. The agents' own row says "Claude", and
    /// this says the same.
    private static func tooltip(for icon: String) -> String {
        SidebarIconID.agent(for: icon)?.displayName ?? icon
    }

    /// Whether some other control in this sheet already shows `icon` as
    /// chosen: a curated cell, an agent's cell, or the emoji field.
    private static func hasOwnCell(_ icon: String) -> Bool {
        switch SidebarIconID.kind(of: icon) {
        case .empty, .emoji, .agent, .unknownAgent:
            return true
        case .symbol:
            return symbols.contains(icon) || agentSymbols.contains(icon)
        }
    }

    /// A quiet heading inside the Icon section, in the caption voice the rest
    /// of these sheets use for anything that is not a control.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The rest of SF Symbols, searchable — what the last cell of the curated
/// grid opens.
///
/// A sheet on top of the editor's sheet, not a popover. Four thousand cells
/// want a scroll view with real height, and a popover hanging off a row of a
/// 330-point-wide form would spend most of that height off the window. A
/// sheet also keeps Escape meaning "close the browser" rather than "close the
/// editor and lose the name I typed".
private struct SidebarIconBrowser: View {
    /// Read, not written. The picker owns what a pick means — the emoji field
    /// to clear, the Recents row to extend — so this hands the name back and
    /// closes rather than writing through a binding and leaving the picker to
    /// work out where the new value came from.
    let selection: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    /// Held rather than recomputed in `body`, which reads the list twice —
    /// once for the grid and once for the count — and would search the
    /// catalogue twice per keystroke for it.
    @State private var results: [String] = []

    @FocusState private var queryFocused: Bool

    /// Ten columns against the picker's seven: this sheet is wider, and the
    /// point here is to sweep a lot of symbols with your eyes rather than to
    /// keep the rhythm of the curated grid.
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 10
    )

    var body: some View {
        VStack(spacing: 0) {
            search

            Divider()

            if results.isEmpty {
                Spacer()
                Text("No symbols match.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(results, id: \.self) { symbol in
                            SidebarIconCell(isSelected: selection == symbol) {
                                onPick(symbol)
                                dismiss()
                            } mark: {
                                Image(systemName: symbol)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(selection == symbol ? .white : .primary)
                            }
                            .help(symbol)
                        }
                    }
                    .padding(10)
                }
            }

            Divider()

            HStack {
                Text(verbatim: "\(results.count) symbols")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 470, height: 520)
        .onAppear {
            results = SidebarIconCatalog.matches(query)
            queryFocused = true
        }
        .onChange(of: query) { value in
            results = SidebarIconCatalog.matches(value)
        }
    }

    /// The same field the file explorer and the worktree panel use: no submit
    /// button, filters as you type, and a clear button only once there is
    /// something to clear.
    private var search: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Search symbols", text: $query)
                .textFieldStyle(.plain)
                .focused($queryFocused)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(10)
    }
}

/// A circular swatch for an arbitrary color (theme palette entries).
private struct SidebarHexSwatch: View {
    let nsColor: NSColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(
                        isSelected ? Color.primary.opacity(0.6) : .clear,
                        lineWidth: 1.5
                    )
                    .frame(width: 22, height: 22)

                Circle()
                    .fill(Color(nsColor: nsColor))
                    .frame(width: 15, height: 15)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Both color rows used by the group and tab editors: the preset
/// palette ("General") plus the current theme's ANSI colors.
private struct SidebarColorRows: View {
    @Binding var color: TerminalTabColor
    @Binding var colorHex: String?

    @ObservedObject private var palette: ThemePalette = .shared

    private let themeColumns = Array(
        repeating: GridItem(.flexible(), spacing: 4),
        count: 8
    )

    var body: some View {
        LabeledContent("Color") {
            HStack(spacing: 6) {
                ForEach(TerminalTabColor.allCases, id: \.self) { swatch in
                    SidebarColorSwatch(
                        color: swatch,
                        isSelected: color == swatch && colorHex == nil
                    ) {
                        color = swatch
                        colorHex = nil
                    }
                }
            }
        }

        if !palette.colors.isEmpty {
            LabeledContent("Theme") {
                LazyVGrid(columns: themeColumns, spacing: 4) {
                    ForEach(Array(palette.colors.enumerated()), id: \.offset) { _, nsColor in
                        let hex = nsColor.hexString ?? ""
                        SidebarHexSwatch(
                            nsColor: nsColor,
                            isSelected: colorHex == hex
                        ) {
                            colorHex = hex
                        }
                    }
                }
            }
        }

        LabeledContent("Custom") {
            ColorPicker("", selection: customColor, supportsOpacity: false)
                .labelsHidden()
        }
    }

    /// The two presets rows offer a fixed set; this is anything else.
    ///
    /// Writes through the same `colorHex` the theme swatches use, so the
    /// three are one choice rather than three competing ones — picking a
    /// custom colour deselects the theme swatch by making the hex stop
    /// matching it, with no extra state to keep in step.
    ///
    /// The accent stands in when nothing is set, because a colour well has to
    /// show *something*, and showing the colour the row would use anyway is
    /// less of a lie than showing black.
    private var customColor: Binding<Color> {
        Binding(
            get: {
                guard let colorHex, let nsColor = NSColor(hex: colorHex) else {
                    return palette.accent ?? .accentColor
                }
                return Color(nsColor: nsColor)
            },
            set: { colorHex = NSColor($0).hexString }
        )
    }
}

/// One circular color swatch, ringed when selected — the Reminders
/// list-editor pattern.
private struct SidebarColorSwatch: View {
    let color: TerminalTabColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(
                        isSelected ? Color.primary.opacity(0.6) : .clear,
                        lineWidth: 1.5
                    )
                    .frame(width: 22, height: 22)

                if let accent = color.sidebarAccent {
                    Circle()
                        .fill(accent)
                        .frame(width: 15, height: 15)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1)
                        .frame(width: 15, height: 15)
                        .overlay(
                            Image(systemName: "line.diagonal")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .help(color.localizedName)
    }
}

/// Per-tab customization sheet: custom display name, icon and color dot.
private struct SidebarTabEditor: View {
    let surfaceId: UUID
    let currentTitle: String
    @ObservedObject var store: SidebarGroupStore

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var palette: ThemePalette = .shared

    @State private var name = ""
    @State private var icon = ""
    @State private var color: TerminalTabColor = .none
    @State private var colorHex: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField(
                            "",
                            text: $name,
                            prompt: Text(currentTitle.isEmpty ? "Terminal" : currentTitle)
                        )
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    SidebarColorRows(color: $color, colorHex: $colorHex)
                } footer: {
                    Text("Leave the name empty to keep the terminal's own title.")
                        .font(palette.captionFont)
                        .foregroundStyle(.secondary)
                }

                Section("Icon") {
                    SidebarIconPicker(selection: $icon)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Reset") {
                    store.setTabOverride(surfaceId: surfaceId, .init())
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 365, height: 460)
        .onAppear { populate() }
    }

    private func populate() {
        guard let override = store.tabOverrides[surfaceId] else { return }
        name = override.name ?? ""
        icon = override.icon ?? ""
        color = override.color ?? .none
        colorHex = override.colorHex
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        store.setTabOverride(surfaceId: surfaceId, .init(
            name: trimmed.isEmpty ? nil : trimmed,
            icon: icon.isEmpty ? nil : icon,
            color: color == .none ? nil : color,
            colorHex: colorHex
        ))
        SidebarIconRecents().record(icon)
    }
}

/// Popover to create or edit a group: name, icon (emoji or SF Symbol),
/// project root for rule-based groups, and color.
private struct SidebarGroupEditor: View {
    let group: SidebarGroup?
    @ObservedObject var store: SidebarGroupStore

    /// When creating a group from a tab's context menu, the tab to move
    /// into the new group on save.
    var assignSurfaceId: UUID?

    /// Every tab to move in, for the gestures that group more than one —
    /// "create group from worktree" stands for all the terminals working
    /// there, and moving only one of them in would leave the group meaning
    /// something narrower than what was asked for.
    var assignSurfaceIds: [UUID] = []

    /// A name to arrive with. The reader can change it; what it saves is a
    /// blank field in the one case where there *is* an obvious name — the
    /// branch the worktree is on — and typing it out again is work the
    /// gesture already knew the answer to.
    var initialName: String?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var palette: ThemePalette = .shared

    @State private var name: String = ""
    @State private var details: String = ""
    @State private var icon: String = "folder"
    @State private var color: TerminalTabColor = .none
    @State private var colorHex: String?
    @State private var isProject: Bool = false
    @State private var projectRoot: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("", text: $name, prompt: Text("Group name"))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    LabeledContent("Description") {
                        TextField("", text: $details, prompt: Text("Optional"))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    SidebarColorRows(color: $color, colorHex: $colorHex)
                }

                Section("Icon") {
                    SidebarIconPicker(selection: $icon)
                }

                Section {
                    Toggle("Project group", isOn: $isProject)
                        .toggleStyle(.switch)

                    if isProject {
                        HStack(spacing: 6) {
                            TextField(
                                "",
                                text: $projectRoot,
                                prompt: Text("~/Projects")
                            )
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                if let pasted = NSPasteboard.general.string(forType: .string) {
                                    projectRoot = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help("Paste Path")

                            Button {
                                chooseProjectRoot()
                            } label: {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help("Choose Folder…")
                        }
                    }
                } footer: {
                    Text("Project groups automatically claim tabs whose working directory is inside the project root.")
                        .font(palette.captionFont)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(group == nil ? "Create" : "Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 420, height: 860)
        .onAppear { populate() }
    }

    private func populate() {
        guard let group else {
            if let initialName, name.isEmpty { name = initialName }
            return
        }
        name = group.name
        details = group.details ?? ""
        icon = group.icon
        color = group.color
        colorHex = group.colorHex
        if case .project(let root) = group.kind {
            isProject = true
            projectRoot = root
        }
    }

    /// Opens a Finder panel to pick the project root directory.
    private func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !projectRoot.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: (projectRoot as NSString).expandingTildeInPath
            )
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectRoot = (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func save() {
        let kind: SidebarGroup.Kind = isProject && !projectRoot.isEmpty
            ? .project(root: projectRoot)
            : .manual

        let trimmedDetails = details.trimmingCharacters(in: .whitespaces)

        if let group {
            store.update(group.id) {
                $0.name = name
                $0.details = trimmedDetails.isEmpty ? nil : trimmedDetails
                $0.icon = icon
                $0.color = color
                $0.colorHex = colorHex
                $0.kind = kind
            }
        } else {
            let created = store.createGroup(
                name: name,
                details: trimmedDetails.isEmpty ? nil : trimmedDetails,
                icon: icon,
                color: color,
                kind: kind
            )
            if let colorHex {
                store.update(created.id) { $0.colorHex = colorHex }
            }
            /// Deduplicated, so a caller that passes both a single tab and a
            /// list containing it does not assign it twice.
            for surfaceId in Set([assignSurfaceId].compactMap { $0 } + assignSurfaceIds) {
                store.assign(surfaceId: surfaceId, to: created.id)
            }
        }

        SidebarIconRecents().record(icon)
    }
}
