import AppKit
import Combine
import SwiftUI

/// The Git panel.
///
/// Takes one of two shapes, decided by `GitPanelScope`. A terminal inside a
/// repository gets that repository, filling the pane — the panel this
/// started as. A terminal sitting in a folder that merely *contains*
/// repositories gets one collapsible section per repository, because a
/// workspace like `~/Projects/Acme` is a real place to work from and
/// answering "this terminal isn't in a git repository" while sitting on top
/// of five of them was never useful.
///
/// The per-repository half lives in `GitRepoView`, which owns its own
/// commit message and dialogs. That is what lets several of them coexist
/// without this view juggling a dictionary of half-typed messages.
struct GitPanelView: View {
    @ObservedObject var tabManager: SidebarTabManager

    /// Which file the editor is showing, so a row can say it is that one.
    /// Held here only to hand down; this view draws no rows itself.
    @ObservedObject var editorCenter: EditorCenter

    /// Opens a terminal beside the selected one; every file opened here
    /// gets its own. See `FileOpener.openInTerminal`.
    var onSpawnTerminal: () -> Ghostty.SurfaceView? = { nil }

    /// Opens the file in this window's editor pane.
    var onOpenInEditor: (URL) -> Void = { _ in }

    /// See `GitRepoView.onOpenDiff`.
    var onOpenDiff: ((URL) -> Void)?

    /// See `GitRepoView.onOpenBranchDiff`.
    var onOpenBranchDiff: ((URL, String) -> Void)?

    @ObservedObject private var center: GitCenter = .shared
    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var refresh: GitPanelRefresh = .shared

    @State private var repoRoot: String?
    @State private var pwd: String?

    /// Sections the user opened or closed by hand, which always win over
    /// the automatic rule. See `GitRepoExpansion`.
    @State private var manualExpansion: [String: Bool] = [:]

    private var selectedTab: SidebarTabModel? {
        tabManager.models.first { $0.isSelected }
    }

    private var discovered: [String]? {
        pwd.flatMap { center.workspaceRepos[$0] }
    }

    private var scope: GitPanelScope {
        GitPanelScope.resolve(repoRoot: repoRoot, pwd: pwd, discovered: discovered)
    }

    /// The scan hasn't answered yet. Distinguished from a genuinely empty
    /// folder so the "isn't in a git repository" message doesn't flash on
    /// screen for a moment every time you switch to a workspace tab.
    private var isScanning: Bool {
        (repoRoot ?? "").isEmpty && !(pwd ?? "").isEmpty && discovered == nil
    }

    var body: some View {
        content
            .onAppear { syncScope() }
            // The repository changes from outside this panel constantly —
            // the terminal right next to it is where most of the committing
            // still happens. Nothing publishes that, so the panel polls
            // while it's the one on screen; `requestStatus` is a no-op
            // until the TTL is up.
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                polledRoots.forEach { center.requestStatus(root: $0) }
            }
            .onChange(of: tabManager.groupingVersion) { _ in syncScope() }
            .onChange(of: refresh.token) { _ in forceRefresh() }
            // Selection lives on the individual model, not on the published
            // array, so the array alone never announces it. The async hop is
            // required: objectWillChange fires *before* the value is written.
            .onReceive(
                Publishers.MergeMany(tabManager.models.map { $0.objectWillChange })
            ) { _ in
                DispatchQueue.main.async { syncScope() }
            }
            // A sheet rather than something inline: git's failures are
            // paragraphs, and rendering one inside a 240pt sidebar column
            // stretched the pane's intrinsic height until the window itself
            // was dragged into a tall thin sliver. It stays on the panel
            // rather than in a section because a failure belongs to the
            // window, not to one repository's row.
            .sheet(item: $center.lastError) { error in
                GitFailureSheet(operation: error.operation, failure: error.failure)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch scope {
        case .repository(let root):
            repoView(root, style: .standalone)

        case .workspace(_, let repos):
            workspaceList(repos)

        case .none:
            if isScanning {
                scanningState
            } else {
                empty
            }
        }
    }

    private func repoView(_ root: String, style: GitRepoStyle) -> GitRepoView {
        GitRepoView(
            root: root,
            style: style,
            editorCenter: editorCenter,
            selectedTab: selectedTab,
            onSpawnTerminal: onSpawnTerminal,
            onOpenInEditor: onOpenInEditor,
            onOpenDiff: onOpenDiff,
            onOpenBranchDiff: onOpenBranchDiff
        )
    }

    private func workspaceList(_ repos: [String]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(repos.enumerated()), id: \.element) { index, repo in
                    if needsDivider(above: index, in: repos) {
                        Divider()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }

                    repoView(repo, style: .section(
                        name: (repo as NSString).lastPathComponent,
                        isExpanded: isExpanded(repo),
                        onToggle: { toggle(repo) }
                    ))
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.automatic)
    }

    private func needsDivider(above index: Int, in repos: [String]) -> Bool {
        GitRepoExpansion.needsDivider(above: index, expanded: repos.map(isExpanded))
    }

    // MARK: States

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

    private var empty: some View {
        VStack(spacing: 6) {
            GitIcon(size: 22)
                .foregroundStyle(.tertiary)
            Text("No git repository here or below")
                .font(palette.captionFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: Expansion

    private func isExpanded(_ repo: String) -> Bool {
        GitRepoExpansion.isExpanded(
            manual: manualExpansion[repo],
            status: center.status(forRoot: repo)
        )
    }

    private func toggle(_ repo: String) {
        let next = !isExpanded(repo)
        withAnimation(.easeOut(duration: 0.15)) {
            manualExpansion[repo] = next
        }
    }

    // MARK: Syncing

    /// Only what is open gets polled. A workspace of ten repositories would
    /// otherwise spawn ten `git status` every couple of seconds, and nine
    /// of those answers would be for a collapsed section nobody is reading.
    private var polledRoots: [String] {
        switch scope {
        case .repository(let root): return [root]
        case .workspace(_, let repos): return repos.filter { isExpanded($0) }
        case .none: return []
        }
    }

    /// Follows the selected terminal: its repository if it is in one, else
    /// the repositories under its folder.
    private func syncScope() {
        let tab = selectedTab
        let nextRepo = tab?.repoRoot
        let nextPwd = tab?.pwd

        if nextRepo != repoRoot || nextPwd != pwd {
            repoRoot = nextRepo
            pwd = nextPwd
            // A different folder is a different set of sections, so the
            // choices made about the old ones don't apply.
            manualExpansion = [:]
        }

        if let nextRepo, !nextRepo.isEmpty {
            center.requestStatus(root: nextRepo)
            return
        }

        guard let nextPwd, !nextPwd.isEmpty else { return }
        center.requestWorkspaceRepos(root: nextPwd)
        // Every repository gets one status even while collapsed: it is what
        // the section header's counts show, and what decides which sections
        // open on their own.
        (center.workspaceRepos[nextPwd] ?? []).forEach { center.requestStatus(root: $0) }
    }

    private func forceRefresh() {
        if let pwd, !pwd.isEmpty, (repoRoot ?? "").isEmpty {
            center.requestWorkspaceRepos(root: pwd, force: true)
        }
        scope.repos.forEach { center.requestStatus(root: $0, force: true) }
    }
}

/// A change plus which section is showing it.
///
/// The section has to be part of the row's identity. A path can legitimately
/// appear twice — a file staged and then edited again is in both Staged
/// Changes and Changes — so identifying rows by path alone puts duplicate
/// ids in one list. It also lets SwiftUI match a row against the
/// same-named row in the *other* section when a file moves between them,
/// which it does on every stage: the row kept the props it had before the
/// move, so a freshly staged file went on showing its untracked badge and
/// a "stage" button that no longer applied.
struct SectionRow: Identifiable {
    let change: GitFileChange
    let section: String

    var id: String { "\(section)/\(change.path)" }
}

/// One changed path.
struct GitChangeRow: View {
    let change: GitFileChange
    let staged: Bool

    /// The file itself, for the two items that only need to point at it.
    ///
    /// An absolute URL where the repository root was deliberately withheld,
    /// which is a narrower thing to hand over than it looks: revealing a file
    /// and copying its path are reads. Every action that *changes* anything is
    /// still a callback, so the row remains unable to write to disk.
    let url: URL

    /// Whether this row's file is the one the editor is showing.
    ///
    /// The Git panel is a checklist while a merge is being resolved: which
    /// file is on screen is the reader's place in it, and a list with no mark
    /// leaves them counting rows against tab titles. The Files tree already
    /// answers this, and the two share `FileExplorerRowEmphasis` so they
    /// cannot come to disagree about what "open" looks like.
    var isOpenInEditor = false

    let onOpen: () -> Void
    let onPrimary: () -> Void
    let onDiscard: (() -> Void)?

    /// The diff, with no detour through the open dialog — see
    /// `GitRepoView.openDiff`. Optional so a host that has not wired it gets a
    /// menu without the item rather than one that does nothing.
    var onOpenDiff: (() -> Void)?

    /// The file as it stands, wherever the reader has said files should open.
    var onOpenSource: (() -> Void)?

    /// Adds this path to the repository's `.gitignore`.
    ///
    /// A callback rather than the row doing it, because the row does not know
    /// the repository root — and giving it one would make every row able to
    /// write to disk.
    var onIgnore: (() -> Void)?

    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var icons: FileIconProvider = .shared
    @State private var isHovered = false

    private var accent: Color { palette.accent ?? .accentColor }

    /// The same three states the Files tree paints, from the same rule.
    private var rowFill: Color {
        switch FileExplorerRowEmphasis.resolve(
            isOpenInEditor: isOpenInEditor,
            isSelected: false,
            isHovered: isHovered
        ).fill {
        case .open: accent.opacity(0.45)
        case .hover: accent.opacity(0.12)
        case .none: .clear
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            // The name is its own hit target rather than the whole row
            // being one: the row also carries the action buttons, and a
            // row-wide gesture would swallow their clicks and their
            // tooltips along with them.
            Button(action: onOpen) {
                HStack(spacing: 5) {
                    FileIconView(icon: icons.icon(forFile: change.name), size: 13)

                    Text(change.name)
                        .font(palette.font(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !change.directory.isEmpty {
                        Text(change.directory)
                            .font(palette.font(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(change.path)

            if isHovered {
                if let onDiscard {
                    rowButton("arrow.uturn.backward", help: "Discard Changes", action: onDiscard)
                }
                rowButton(
                    staged ? "minus" : "plus",
                    help: staged ? "Unstage" : "Stage",
                    action: onPrimary
                )
            } else {
                // Same box as the buttons that replace it on hover. A
                // bare label is shorter than a 22pt button, so without
                // this the row grew the moment the pointer touched it and
                // the whole list twitched.
                Text(change.badge(staged: staged))
                    .font(palette.font(size: 11, weight: .semibold))
                    .foregroundStyle(badgeColor)
                    .frame(width: Self.actionSize, height: Self.actionHeight)
            }
        }
        .frame(height: SidebarIconChipMetrics.rowHeight)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowFill)
        )
        .onHover { isHovered = $0 }
        .contextMenu { menu }
    }

    /// Everything this row can do, which used to be one item.
    ///
    /// Which items appear is `GitRowAction.groups` and not this view: those are
    /// rules about git's vocabulary, and they are checked without a menu on
    /// screen. All that is left here is doing them.
    @ViewBuilder
    private var menu: some View {
        let groups = GitRowAction.groups(
            for: change,
            staged: staged,
            canDiscard: onDiscard != nil,
            canIgnore: onIgnore != nil
        )

        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { Divider() }

            ForEach(groups[index], id: \.self) { action in
                Button(
                    action.title,
                    role: action.isDestructive ? .destructive : nil
                ) {
                    perform(action)
                }
            }
        }
    }

    private func perform(_ action: GitRowAction) {
        switch action {
        case .openDiff: (onOpenDiff ?? onOpen)()
        case .openFile: (onOpenSource ?? onOpen)()
        case .stage, .unstage: onPrimary()
        case .discardChanges, .deleteUntrackedFile: onDiscard?()
        case .addToGitignore: onIgnore?()
        case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .copyPath: copy(url.path)
        case .copyRelativePath: copy(change.path)
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Matches `SidebarIconButton`'s hit area exactly, so swapping the
    /// badge for the buttons on hover changes nothing about the layout.
    private static let actionSize = SidebarIconChipMetrics.width
    private static let actionHeight = SidebarIconChipMetrics.height

    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        SidebarIconButton(help: help, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var badgeColor: Color {
        switch change.badge(staged: staged) {
        case "M": return .orange
        case "A": return .green
        case "D": return .red
        case "R", "C": return .blue
        case "U": return .purple
        default: return .secondary
        }
    }
}

/// Explains a failed git operation: what happened, what to do, and the
/// transcript underneath for when that isn't enough.
struct GitFailureSheet: View {
    let operation: String
    let failure: GitFailure

    @Environment(\.dismiss) private var dismiss
    @State private var showsTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 5) {
                    Text(failure.title)
                        .font(.headline)

                    if let summary = failure.summary {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            if !failure.files.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(failure.files, id: \.self) { file in
                        Label(file, systemImage: "doc")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                )
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            // A git that failed without printing anything is rare but real
            // (killed, or exited on a signal). Offering to expand and copy
            // an empty transcript would be a dead end.
            if !failure.raw.isEmpty {
                DisclosureGroup(isExpanded: $showsTranscript) {
                    ScrollView {
                        Text(failure.raw)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    // Bounded on purpose — this is exactly the content that
                    // has no natural size limit.
                    .frame(maxHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    )
                } label: {
                    Text("Git output")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            Spacer(minLength: 12)

            Divider()

            HStack {
                if !failure.raw.isEmpty {
                    Button("Copy Output") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(failure.raw, forType: .string)
                    }
                }
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460)
        .frame(minHeight: 220, maxHeight: 520)
    }
}

/// Names a new branch. Same skeleton as the sidebar's other editors.
struct GitBranchCreator: View {
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("", text: $name, prompt: Text("feat/my-change"))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } footer: {
                    Text("Branches off whatever is currently checked out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    onCreate(name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 360, height: 200)
    }
}

/// Lets the titlebar's refresh button reach the panel, same shape as
/// `FileExplorerRefresh` and for the same ownership reason.
@MainActor
final class GitPanelRefresh: ObservableObject {
    static let shared = GitPanelRefresh()

    @Published private(set) var token = 0

    func request() {
        token &+= 1
    }
}
