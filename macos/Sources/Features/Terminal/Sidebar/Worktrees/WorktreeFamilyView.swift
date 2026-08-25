import AppKit
import SwiftUI

/// How one repository family presents itself inside the worktrees panel.
enum WorktreeFamilyStyle {
    /// The only family there is. The panel is about it, so it fills the pane,
    /// carries the search field and scrolls its own list.
    case standalone

    /// One of several under a workspace folder, behind a disclosure row.
    ///
    /// Its list must **not** scroll: the panel already scrolls the whole
    /// stack of sections, and two scroll views on the same axis fight each
    /// other for the gesture and for height.
    case section(isExpanded: Bool, onToggle: () -> Void)
}

/// One repository's worktrees, and everything you can do to them.
///
/// Owns its own dialogs — the creator, the removal alert, the prune
/// confirmation, the repair picker — because each of them is about *this*
/// repository. That is what lets a workspace show several of these at once
/// without the panel keeping a dictionary of which repository each
/// half-answered dialog belonged to. Only the failure sheet stays on the
/// panel: a git refusal belongs to the window, not to one section.
struct WorktreeFamilyView: View {
    let commonRoot: String
    var style: WorktreeFamilyStyle = .standalone

    /// The search text, when the panel owns it.
    ///
    /// A workspace has one field above all its sections rather than one per
    /// section, so the filter arrives from outside and the section draws no
    /// field of its own. Standalone keeps its own, which is why this is
    /// optional rather than a plain `String`.
    var sharedFilter: String?

    @ObservedObject var tabManager: SidebarTabManager

    /// For one sentence in the removal alert — see `removalAlert`.
    @ObservedObject var editorCenter: EditorCenter

    let onNewTerminal: (String) -> Void
    let onNewAgentTab: (String, CodingAgent) -> Void

    @ObservedObject private var center: WorktreeCenter = .shared
    @ObservedObject private var git: GitCenter = .shared
    @ObservedObject private var palette: ThemePalette = .shared

    @AppStorage("SidebarShowClaude") private var showClaude = AgentButtonDefaults.isShown(.claude)
    @AppStorage("SidebarShowCodex") private var showCodex = AgentButtonDefaults.isShown(.codex)
    @AppStorage("SidebarShowOpenCode") private var showOpenCode = AgentButtonDefaults.isShown(.opencode)
    @AppStorage("SidebarShowAntigravity") private var showAntigravity = AgentButtonDefaults.isShown(.antigravity)
    @AppStorage("SidebarShowKimi") private var showKimi = AgentButtonDefaults.isShown(.kimi)
    @AppStorage("SidebarShowPi") private var showPi = AgentButtonDefaults.isShown(.pi)

    @State private var ownFilter = ""

    private var filter: String { sharedFilter ?? ownFilter }
    @State private var isCreating = false
    @State private var creationBase: String?
    @State private var removal: GitWorktree?
    @State private var pruneConfirm = false
    @State private var repairTarget: String?

    private var selectedTab: SidebarTabModel? {
        tabManager.models.first { $0.isSelected }
    }

    private var worktrees: [GitWorktree] {
        center.list(forRoot: commonRoot)
    }

    var body: some View {
        content
            .sheet(isPresented: $isCreating) {
                WorktreeCreator(
                    commonRoot: commonRoot,
                    initialBase: creationBase,
                    onDone: {
                        isCreating = false
                        creationBase = nil
                    },
                    onOpenTerminal: onNewTerminal)
            }
            .alert(item: $removal) { worktree in
                removalAlert(worktree)
            }
            .confirmationDialog(
                "Forget broken worktrees?",
                isPresented: $pruneConfirm
            ) {
                Button("Forget", role: .destructive) {
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
                guard case .success(let url) = result else { return }
                center.repair(path: url.path, commonRoot: commonRoot) { _ in }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .standalone:
            VStack(spacing: 0) {
                header
                search
                ScrollView { list(showsLoadState: false) }
            }

        case .section(let isExpanded, let onToggle):
            VStack(spacing: 0) {
                sectionHeader(isExpanded: isExpanded, onToggle: onToggle)
                if isExpanded {
                    list(showsLoadState: true)
                }
            }
        }
    }

    /// The explorer header's shape, so the four panels read as one family:
    /// the repo's name in the theme's own semibold, and the actions as the
    /// shared icon chips.
    private var header: some View {
        HStack(spacing: 4) {
            Text(verbatim: name)
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

            newWorktreeButton
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// The disclosure row for one repository in a workspace.
    ///
    /// Wears the Git panel's section header, down to the chevron and the row
    /// height, because the two panels are answering the same question about
    /// the same folder and a reader switching between them should not have to
    /// re-learn where to click.
    ///
    /// The count is shown only once the section is open. A collapsed section
    /// is never listed — see `WorktreeScope.polled` — so a badge there would
    /// read as "no worktrees" for every repository nobody has expanded yet,
    /// which is worse than no badge at all.
    private func sectionHeader(
        isExpanded: Bool,
        onToggle: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 5) {
            Button(action: onToggle) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)

                    Text(verbatim: name)
                        .font(palette.font(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isExpanded, !worktrees.isEmpty {
                        SidebarCountBadge(
                            count: worktrees.count,
                            symbol: "arrow.triangle.branch")
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let operation = center.busy[commonRoot] {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                    .help(operation)
            }

            newWorktreeButton
        }
        .foregroundStyle(.secondary)
        .frame(height: SidebarIconChipMetrics.rowHeight)
        .padding(.leading, 8)
        .padding(.trailing, 6)
    }

    /// Also opens the list, which the creator reads to know which branches
    /// are already checked out somewhere. Asking here rather than polling is
    /// the whole bargain of a collapsed section: an explicit action pays for
    /// what it needs.
    private var newWorktreeButton: some View {
        SidebarIconButton(help: "New Worktree") {
            center.requestList(commonRoot: commonRoot)
            isCreating = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
        }
    }

    /// The explorer's search treatment, verbatim: always there, filters as
    /// you type, no Return to press.
    ///
    /// Standalone only. In a workspace the sections themselves are what you
    /// navigate by, and a field that searched across them would have to
    /// either leave the matches hidden inside collapsed sections or open
    /// every section to show them — which is the poll this panel refuses.
    private var search: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            TextField("Search worktrees", text: $ownFilter)
                .textFieldStyle(.plain)
                .font(palette.font(size: 11))

            if !ownFilter.isEmpty {
                Button {
                    ownFilter = ""
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

    /// - Parameter showsLoadState: whether an empty list says why it is
    ///   empty. Sections need it — clicking one open and getting nothing for
    ///   a moment reads as a broken click — while the flat panel deliberately
    ///   keeps the layout it was validated with, and only ever shows an empty
    ///   list for a repository git could not read.
    private func list(showsLoadState: Bool) -> some View {
        let tabs = tabsByWorktree()
        let findings = WorktreeFindings.derive(
            worktrees: worktrees,
            merged: center.merged(forRoot: commonRoot),
            tabsByPath: tabs,
            managedRoot: WorktreeSettings.managedRoot)

        let visible = filteredWorktrees

        /// The sidebar's one rhythm: same gap between items and same outer
        /// padding as the terminal list, so switching panes does not shift
        /// the eye.
        return VStack(alignment: .leading, spacing: SidebarMetrics.itemSpacing) {
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
                    onUnlock: { worktree in
                        center.unlock(path: worktree.path, commonRoot: commonRoot) { _ in }
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

            /// A repository git could not read, told apart from one whose
            /// first list is still on its way — the same distinction
            /// `WorktreeCenter.loadedRoots` exists for, and the reason this
            /// is not a spinner that would turn forever.
            if showsLoadState, visible.isEmpty, filter.isEmpty {
                Text(center.hasLoaded(commonRoot) ? "No worktrees here" : "Reading worktrees…")
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

    private var name: String {
        (commonRoot as NSString).lastPathComponent
    }

    private var offeredAgents: [CodingAgent] {
        CodingAgent.allCases.filter { agent in
            switch agent {
            case .claude: return showClaude
            case .codex: return showCodex
            case .opencode: return showOpenCode
            case .antigravity: return showAntigravity
            case .kimi: return showKimi
            case .pi: return showPi
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

    /// Open documents with unsaved edits that live inside a worktree.
    ///
    /// Read off the editor's own tab set rather than from the documents map,
    /// so the order matches the tab bar and a media tab — which has no
    /// buffer and cannot be dirty — never appears.
    private func unsavedDocuments(in root: String) -> [String] {
        editorCenter.tabs.tabs
            .filter { $0.isDirty && EditorChangeLookup.isDescendant(path: $0.path, ofRoot: root) }
            .map(\.path)
    }

    private func isCurrent(_ worktree: GitWorktree) -> Bool {
        GitWorktreeMembership.contains(pwd: selectedTab?.pwd, root: worktree.path)
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
        let status = git.status(forRoot: worktree.path)
        let dirty = status.map { !$0.isClean } ?? false
        let tabs = rowTabs(tabsByWorktree()[worktree.path] ?? [])
        let merged = worktree.branch.map {
            center.merged(forRoot: commonRoot).contains($0)
        } ?? false

        let message = Text(WorktreeRemovalNote.message(
            path: worktree.path,
            isDirty: dirty,
            terminalCount: tabs.count,
            unsavedFiles: unsavedDocuments(in: worktree.path)))

        /// A lock is answered before anything else, because it is the one
        /// state where none of the buttons below can succeed. Git refuses a
        /// locked worktree, and refuses it through the force this pane
        /// sends — so offering "Remove Anyway" would be a destructive
        /// confirm for something that cannot happen, and the reader only
        /// learns that after pressing it.
        if worktree.isLocked {
            return Alert(
                title: Text("This worktree is locked"),
                message: Text(WorktreeLockNote.text(reason: worktree.lockReason)
                    + "\n\nUnlock it first, then remove it."),
                primaryButton: .default(Text("Unlock")) {
                    center.unlock(path: worktree.path, commonRoot: commonRoot) { _ in }
                },
                secondaryButton: .cancel())
        }

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
    let onUnlock: (GitWorktree) -> Void
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

                        /// Beside the padlock rather than after the sentence
                        /// below it. The sentence wraps, and a trailing icon
                        /// on a wrapping paragraph lands wherever the last
                        /// line happens to end — mid-thought, and somewhere
                        /// different on every window width.
                        WorktreeLockInfo(
                            reason: worktree.lockReason,
                            path: worktree.path,
                            onUnlock: { onUnlock(worktree) })
                    }
                }

                /// On the row, not in a tooltip. The padlock is a good
                /// glance-level marker and a bad explanation: a lock is a
                /// state somebody chose, and what a reader needs from it is
                /// what it does to them — which they will otherwise meet as
                /// a remove that fails for no visible reason.
                if worktree.isLocked {
                    Text(WorktreeLockNote.text(reason: worktree.lockReason))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

    /// The badge says *that* it is locked; git's own reason says why, and it
    /// is the thing that decides whether the lock still applies — "on the
    /// external drive" reads very differently once the drive is back.
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
        /// Unlocking and removing share a group because they are steps of
        /// the same errand: a locked worktree is one git refuses to remove,
        /// so the two items are read in that order or not at all. Both sit
        /// under the main-checkout guard — git declines to lock the main
        /// worktree at all, so a locked one is by definition linked.
        if !worktree.isMain {
            Divider()
            if worktree.isLocked {
                Button("Unlock") { onUnlock(worktree) }
            }
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
