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

/// The sidebar's worktree panel: every place this repository is checked out,
/// who is working there, and what is finished with.
///
/// Follows the selected terminal the way Files and Git do — same triple of
/// subscriptions, same reason for each. The repository shown is the **main
/// checkout's**: a tab sitting inside a linked worktree resolves through
/// `GitCommonDir` so the panel always describes the whole family, not the
/// one member the tab happens to be in.
struct WorktreePanelView: View {
    @ObservedObject var tabManager: SidebarTabManager
    let onNewTerminal: (String) -> Void
    let onNewAgentTab: (String, CodingAgent) -> Void

    @ObservedObject private var center: WorktreeCenter = .shared
    @ObservedObject private var git: GitCenter = .shared
    @ObservedObject private var refresh: WorktreePanelRefresh = .shared
    @ObservedObject private var palette: ThemePalette = .shared

    @AppStorage("SidebarShowClaude") private var showClaude = true
    @AppStorage("SidebarShowCodex") private var showCodex = true
    @AppStorage("SidebarShowOpenCode") private var showOpenCode = true

    @State private var commonRoot: String?
    @State private var filter = ""
    @State private var isCreating = false
    @State private var creationBase: String?
    @State private var removal: GitWorktree?
    @State private var pruneConfirm = false
    @State private var repairTarget: String?

    private var selectedTab: SidebarTabModel? {
        tabManager.models.first { $0.isSelected }
    }

    private var worktrees: [GitWorktree] {
        commonRoot.flatMap { center.worktrees[$0] } ?? []
    }

    var body: some View {
        content
            .onAppear { syncScope() }
            .sheet(isPresented: $isCreating) {
                if let commonRoot {
                    WorktreeCreator(
                        commonRoot: commonRoot,
                        initialBase: creationBase,
                        onDone: {
                            isCreating = false
                            creationBase = nil
                        },
                        onOpenTerminal: onNewTerminal)
                }
            }
            /// Failures arrive as a sheet, exactly like the Git panel's: a
            /// git refusal is paragraphs, and paragraphs do not fit a 240pt
            /// column.
            .sheet(item: $center.lastError) { error in
                GitFailureSheet(operation: error.operation, failure: error.failure)
            }
            .alert(item: $removal) { worktree in
                removalAlert(worktree)
            }
            .confirmationDialog(
                "Forget broken worktrees?",
                isPresented: $pruneConfirm
            ) {
                Button("Forget", role: .destructive) {
                    guard let commonRoot else { return }
                    center.prune(commonRoot: commonRoot) { _ in }
                }
            } message: {
                Text("Runs git worktree prune: entries whose folders are gone are removed from the repository's records. Nothing on disk is touched.")
            }
            /// Repair asks where the folder went. `git worktree repair` takes
            /// the worktree's *new* location and rewrites both pointers.
            .fileImporter(
                isPresented: Binding(
                    get: { repairTarget != nil },
                    set: { if !$0 { repairTarget = nil } }
                ),
                allowedContentTypes: [.folder]
            ) { result in
                repairTarget = nil
                guard case .success(let url) = result, let commonRoot else { return }
                center.repair(path: url.path, commonRoot: commonRoot) { _ in }
            }
            /// The list changes from outside constantly — the terminal next
            /// door is where `git worktree add` may well be typed. Nothing
            /// publishes that, so the panel polls while on screen; both
            /// requests are no-ops until their TTLs are up.
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                guard let commonRoot else { return }
                center.requestList(commonRoot: commonRoot)
                center.requestMerged(commonRoot: commonRoot)
                for worktree in worktrees where !worktree.isBare {
                    git.requestStatus(root: worktree.path)
                }
            }
            .onChange(of: tabManager.groupingVersion) { _ in syncScope() }
            .onChange(of: refresh.token) { _ in forceRefresh() }
            .onReceive(
                Publishers.MergeMany(tabManager.models.map { $0.objectWillChange })
            ) { _ in
                DispatchQueue.main.async { syncScope() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let commonRoot {
            list(commonRoot)
        } else if selectedTab == nil {
            emptyState("No terminal selected")
        } else {
            emptyState("No git repository here or below")
        }
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

    private func list(_ commonRoot: String) -> some View {
        let tabs = tabsByWorktree()
        let findings = WorktreeFindings.derive(
            worktrees: worktrees,
            merged: center.mergedBranches[commonRoot] ?? [],
            tabsByPath: tabs,
            managedRoot: WorktreeSettings.managedRoot)

        let visible = filteredWorktrees

        return VStack(spacing: 0) {
            header(commonRoot)
            search

            ScrollView {
            /// The sidebar's one rhythm: same gap between items and same
            /// outer padding as the terminal list, so switching panes does
            /// not shift the eye.
            VStack(alignment: .leading, spacing: SidebarMetrics.itemSpacing) {
                ForEach(visible) { worktree in
                    WorktreeRow(
                        worktree: worktree,
                        status: git.status(forRoot: worktree.path),
                        tabs: rowTabs(tabs[worktree.path] ?? []),
                        isCurrent: isCurrent(worktree),
                        onNewTerminal: onNewTerminal,
                        onNewAgentTab: onNewAgentTab,
                        onSelectTab: { tabManager.select($0) },
                        onRemove: { removal = $0 },
                        onBranchFrom: { worktree in
                            creationBase = worktree.branch
                            isCreating = true
                        },
                        agents: offeredAgents)
                }

                if visible.isEmpty, !filter.isEmpty {
                    Text("No worktree matches")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }

                /// Hidden while filtering: the findings point at rows, and
                /// pointing at a row the filter just hid is a treasure hunt.
                if !findings.isEmpty, filter.isEmpty {
                    attention(findings)
                }
            }
            .padding(8)
            }
        }
    }

    /// The explorer header's shape, so the four panels read as one family:
    /// the repo's name in the theme's own semibold, and the actions as the
    /// shared icon chips.
    private func header(_ commonRoot: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: (commonRoot as NSString).lastPathComponent)
                .font(palette.font(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.head)

            if let operation = center.busy[commonRoot] {
                ProgressView().controlSize(.mini)
                Text(verbatim: operation)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            SidebarIconButton(help: "New Worktree") {
                isCreating = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// The explorer's search treatment, verbatim: always there, filters as
    /// you type, no Return to press.
    private var search: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            TextField("Search worktrees", text: $filter)
                .textFieldStyle(.plain)
                .font(palette.font(size: 11))

            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    /// Matched on what the eye searches by: the branch, the folder, and the
    /// terminals inside.
    private var filteredWorktrees: [GitWorktree] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return worktrees }
        let tabs = tabsByWorktree()
        return worktrees.filter { worktree in
            if (worktree.branch ?? "").lowercased().contains(needle) { return true }
            if (worktree.path as NSString).lastPathComponent.lowercased().contains(needle) {
                return true
            }
            return rowTabs(tabs[worktree.path] ?? []).contains {
                ($0.directoryName ?? "").lowercased().contains(needle)
            }
        }
    }

    /// The advisory section. Quiet on purpose: these are suggestions with a
    /// path each, not errors.
    private func attention(_ findings: [WorktreeFinding]) -> some View {
        VStack(alignment: .leading, spacing: SidebarMetrics.itemSpacing) {
            Text("Needs attention")
                .font(palette.font(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                WorktreeFindingRow(
                    finding: finding,
                    onRemove: { removal = $0 },
                    onRepair: { repairTarget = $0 },
                    onForget: { pruneConfirm = true })
            }
        }
    }

    private var offeredAgents: [CodingAgent] {
        CodingAgent.allCases.filter { agent in
            switch agent {
            case .claude: return showClaude
            case .codex: return showCodex
            case .opencode: return showOpenCode
            }
        }
    }

    /// The tabs of every window, matched to worktrees by the one membership
    /// rule — the same one the chip uses, so the two can never disagree.
    private func tabsByWorktree() -> [String: [UUID]] {
        GitWorktreeMembership.tabsByWorktree(
            tabs: tabManager.models.compactMap { model in
                model.surfaceId.map { ($0, model.pwd) }
            },
            worktrees: worktrees)
    }

    private func rowTabs(_ ids: [UUID]) -> [SidebarTabModel] {
        ids.compactMap { id in tabManager.models.first { $0.surfaceId == id } }
    }

    private func isCurrent(_ worktree: GitWorktree) -> Bool {
        GitWorktreeMembership.contains(pwd: selectedTab?.pwd, root: worktree.path)
    }

    private func syncScope() {
        var resolved: String?
        if let root = selectedTab?.repoRoot, !root.isEmpty {
            resolved = GitCommonDir.resolve(from: root)
        }
        if resolved != commonRoot { commonRoot = resolved }
        if let resolved {
            center.requestList(commonRoot: resolved)
            center.requestMerged(commonRoot: resolved)
        }
    }

    /// The removal decision, with each guard as its own sentence.
    ///
    /// Dirty refuses by default: `git worktree remove` would refuse too, so
    /// the alert is the friendly version of an answer the reader was getting
    /// anyway, with the force spelled as the destructive choice it is. Open
    /// tabs never block — their shells keep running either way — but they are
    /// named, because a terminal whose folder vanishes under it is the kind
    /// of surprise this pane exists to prevent.
    private func removalAlert(_ worktree: GitWorktree) -> Alert {
        guard let commonRoot else {
            return Alert(title: Text("No repository selected"))
        }

        let status = git.status(forRoot: worktree.path)
        let dirty = status.map { !$0.isClean } ?? false
        let tabs = rowTabs(tabsByWorktree()[worktree.path] ?? [])
        let merged = worktree.branch.map {
            (center.mergedBranches[commonRoot] ?? []).contains($0)
        } ?? false

        var lines: [String] = [(worktree.path as NSString).abbreviatingWithTildeInPath]
        if dirty { lines.append("It has uncommitted changes.") }
        if !tabs.isEmpty {
            let names = tabs.compactMap(\.directoryName).joined(separator: ", ")
            lines.append("\(tabs.count) terminal\(tabs.count == 1 ? " is" : "s are") working here (\(names)). They stay open, in a folder that no longer exists.")
        }
        let message = Text(lines.joined(separator: "\n"))

        if dirty {
            return Alert(
                title: Text("Worktree has uncommitted changes"),
                message: message,
                primaryButton: .destructive(Text("Remove Anyway")) {
                    center.remove(path: worktree.path, force: true, commonRoot: commonRoot) { _ in }
                },
                secondaryButton: .cancel())
        }

        if merged, let branch = worktree.branch {
            return Alert(
                title: Text("Remove worktree?"),
                message: message,
                primaryButton: .destructive(Text("Remove and Delete Branch")) {
                    center.removeAndDeleteBranch(
                        path: worktree.path, branch: branch, commonRoot: commonRoot) { _ in }
                },
                secondaryButton: .default(Text("Remove Only")) {
                    center.remove(path: worktree.path, force: false, commonRoot: commonRoot) { _ in }
                })
        }

        return Alert(
            title: Text("Remove worktree?"),
            message: message,
            primaryButton: .destructive(Text("Remove")) {
                center.remove(path: worktree.path, force: false, commonRoot: commonRoot) { _ in }
            },
            secondaryButton: .cancel())
    }

    private func forceRefresh() {
        guard let commonRoot else { return }
        center.requestList(commonRoot: commonRoot, force: true)
        center.requestMerged(commonRoot: commonRoot, force: true)
        for worktree in worktrees {
            git.requestStatus(root: worktree.path, force: true)
        }
    }
}

/// One checkout: what it is, how it stands, who is in it.
///
/// Deliberately built from the terminal row's own vocabulary — the theme's
/// font, the same accent wash, the same chip treatment, the hover action as a
/// `SidebarIconButton` — so moving between the two panels asks nothing new of
/// the eye.
private struct WorktreeRow: View {
    let worktree: GitWorktree
    let status: GitStatus?
    let tabs: [SidebarTabModel]
    let isCurrent: Bool
    let onNewTerminal: (String) -> Void
    let onNewAgentTab: (String, CodingAgent) -> Void
    let onSelectTab: (SidebarTabModel) -> Void
    let onRemove: (GitWorktree) -> Void
    let onBranchFrom: (GitWorktree) -> Void
    let agents: [CodingAgent]

    @ObservedObject private var themePalette: ThemePalette = .shared
    @State private var isHovered = false

    /// The chip text baseline the terminal rows use.
    private let chipLineHeight: CGFloat = 11

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: worktree.isMain ? "house" : "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(themePalette.font(
                            size: 12,
                            weight: isCurrent ? .semibold : .regular
                        ))
                        .fixedSize(horizontal: false, vertical: true)

                    if let status, !status.isClean {
                        Circle().fill(.yellow).frame(width: 5, height: 5)
                    }
                    if let status, status.ahead > 0 || status.behind > 0 {
                        Text(verbatim: [
                            status.ahead > 0 ? "↑\(status.ahead)" : nil,
                            status.behind > 0 ? "↓\(status.behind)" : nil,
                        ].compactMap { $0 }.joined(separator: " "))
                            .font(.system(size: 9.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if worktree.isLocked {
                        Image(systemName: "lock")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }

                if !tabs.isEmpty {
                    /// Wrapping, like the terminal rows' own chips: a branch
                    /// or folder name is as long as whoever named it made it.
                    WrapLayout(horizontalSpacing: 4, verticalSpacing: 3) {
                        ForEach(tabs, id: \.surfaceId) { tab in
                            terminalChip(tab)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            /// Only for a row that has a branch to branch from: a detached
            /// worktree has no base, and an unborn one has a name but no ref.
            if worktree.branch != nil, !worktree.isUnborn {
                SidebarIconButton(help: "New Worktree from This Branch") {
                    onBranchFrom(worktree)
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }

            SidebarIconButton(help: "New Terminal Here") {
                onNewTerminal(worktree.path)
            } label: {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu { menu }
    }

    /// The terminal row's own wash, one notch quieter: current reads like a
    /// selection without pretending to be one.
    private var rowBackground: AnyShapeStyle {
        let accent = themePalette.primary.map { Color(nsColor: $0) }
            ?? Color(nsColor: .selectedContentBackgroundColor)

        let opacity: Double = if isCurrent {
            0.4
        } else if isHovered {
            0.24
        } else {
            0.1
        }
        return AnyShapeStyle(accent.opacity(opacity))
    }

    /// A tab, worn the way the terminal rows wear their metadata: the chip
    /// shape, with the terminal glyph saying what kind of thing this is.
    private func terminalChip(_ tab: SidebarTabModel) -> some View {
        Button {
            onSelectTab(tab)
        } label: {
            HStack(alignment: .center, spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 8))
                    .frame(height: chipLineHeight)
                Text(tab.directoryName ?? "terminal")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: chipLineHeight)
            }
            .font(themePalette.font(size: 9))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary.opacity(0.6))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Focus this terminal")
    }

    private var name: String {
        if worktree.isBare { return "(bare)" }
        if let branch = worktree.branch { return branch }
        let sha = worktree.head.map { String($0.prefix(7)) } ?? "?"
        return "\(sha) (detached)"
    }

    @ViewBuilder
    private var menu: some View {
        Button("New Terminal Here") { onNewTerminal(worktree.path) }
        if worktree.branch != nil, !worktree.isUnborn {
            Button("New Worktree from This Branch…") { onBranchFrom(worktree) }
        }
        ForEach(agents, id: \.self) { agent in
            Button("New \(agent.displayName) Session Here") {
                onNewAgentTab(worktree.path, agent)
            }
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: worktree.path)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(worktree.path, forType: .string)
        }
        if !worktree.isMain {
            Divider()
            Button("Remove Worktree…", role: .destructive) { onRemove(worktree) }
        }
    }
}

/// One advisory line: what, why, where.
private struct WorktreeFindingRow: View {
    let finding: WorktreeFinding
    let onRemove: (GitWorktree) -> Void
    let onRepair: (String) -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            action
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// One primary action per finding: the whole point of the section is
    /// that the cleanup is a click, not a hunt.
    @ViewBuilder
    private var action: some View {
        switch finding {
        case .orphan(let worktree), .merged(let worktree):
            /// A glyph rather than a word: the row already says what and why,
            /// and the trash can is the one verb nobody has to read. It warms
            /// to the theme's own red under the pointer — a destructive
            /// control should say so before it is pressed, in the palette the
            /// reader chose.
            DangerIconButton(help: "Remove Worktree…", icon: "trash") {
                onRemove(worktree)
            }

        case .broken(let path, _):
            HStack(spacing: 2) {
                SidebarIconButton(help: "Repair — point at where the folder is now") {
                    onRepair(path)
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                SidebarIconButton(help: "Forget — drop the record, leave the disk alone") {
                    onForget()
                } label: {
                    Image(systemName: "eraser")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbol: String {
        switch finding {
        case .orphan: return "moon.zzz"
        case .merged: return "checkmark.circle"
        case .broken: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch finding {
        case .orphan(let worktree): return worktree.branch ?? worktree.path
        case .merged(let worktree): return worktree.branch ?? worktree.path
        case .broken(let path, _): return (path as NSString).lastPathComponent
        }
    }

    private var detail: String {
        switch finding {
        case .orphan: return "No tab is using this worktree"
        case .merged: return "Branch already merged into the base"
        case .broken(_, let reason): return reason
        }
    }
}

extension GitWorktree {
    /// A checkout whose branch has a name but no commit yet — a fresh
    /// `git init`. The porcelain prints the symbolic HEAD as a branch line
    /// over an all-zero HEAD, so the name cannot be used as a ref.
    var isUnborn: Bool {
        guard let head else { return !isBare }
        return head.allSatisfy { $0 == "0" }
    }
}

/// An icon button that turns the theme's red under the pointer.
///
/// Separate from `SidebarIconButton` rather than a flag on it: that one is
/// used dozens of times for ordinary actions, and the hover treatment here is
/// a promise about consequence, not a style.
private struct DangerIconButton: View {
    let help: String
    let icon: String
    let action: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? danger : Color.secondary)
                .frame(
                    width: SidebarIconChipMetrics.width,
                    height: SidebarIconChipMetrics.height)
                .background(
                    RoundedRectangle(cornerRadius: SidebarIconChipMetrics.cornerRadius)
                        .fill(isHovered ? danger.opacity(0.16) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
    }

    /// The theme's red when it has one — a theme with too few ANSI colours
    /// falls back to the system's rather than to no signal at all.
    private var danger: Color {
        palette.danger ?? .red
    }
}
