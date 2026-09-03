import AppKit
import SwiftUI

/// How a repository presents itself inside the Git panel.
enum GitRepoStyle {
    /// The only repository there is. The panel is about it, so it fills the
    /// pane and scrolls everything below the commit box.
    case standalone

    /// One of several under a workspace folder, behind a disclosure row.
    ///
    /// Its change list must **not** scroll: the panel already scrolls the
    /// whole stack of sections, and two scroll views on the same axis fight
    /// each other for the gesture and for height.
    case section(name: String, isExpanded: Bool, onToggle: () -> Void)
}

/// One repository's working state, and everything you can do to it.
///
/// Owns the per-repository editing state — the commit message above all —
/// which is what lets a workspace show several of these at once without the
/// panel juggling a dictionary of half-typed messages.
struct GitRepoView: View {
    let root: String
    var style: GitRepoStyle = .standalone

    /// The editor, for the one thing this panel asks of it: which file is on
    /// screen. Observed rather than passed as a path, because it changes for
    /// reasons this view does not watch — a tab click, a jump to definition,
    /// the reader closing a tab.
    @ObservedObject var editorCenter: EditorCenter

    /// The terminal the panel is following, for the file-open dialog.
    var selectedTab: SidebarTabModel?

    /// Opens a terminal beside the selected one; every file opened here
    /// gets its own. See `FileOpener.openInTerminal`.
    var onSpawnTerminal: () -> Ghostty.SurfaceView? = { nil }

    /// Opens the file in this window's editor pane.
    var onOpenInEditor: (URL) -> Void = { _ in }

    /// Opening from *here* rather than from the file explorer.
    ///
    /// A file reached by clicking it in a list of changes was chosen for
    /// its changes, so it lands on the diff. Its own callback rather than a
    /// flag on the shared one, so the file explorer keeps opening files the
    /// way it always has.
    ///
    /// Optional, and falls back to the ordinary open: a host that has not
    /// wired it should show the file rather than do nothing, which is what
    /// a defaulted empty closure would have done.
    var onOpenDiff: ((URL) -> Void)?

    /// Opens a file as the branch review sees it — its diff against the base
    /// the review was measured from, which is not the working tree.
    ///
    /// Separate from `onOpenDiff` because the two mean different comparisons
    /// of the same file, and a single callback would have to guess which.
    var onOpenBranchDiff: ((URL, String) -> Void)?

    @ObservedObject private var center: GitCenter = .shared
    @ObservedObject private var palette: ThemePalette = .shared

    @State private var message = ""
    @State private var isAmending = false
    @State private var discarding: [GitFileChange] = []
    @State private var isCreatingBranch = false
    @State private var isUndoingCommit = false

    private var status: GitStatus? { center.status(forRoot: root) }

    private var busy: String? { center.isBusy(root) }

    private var isSection: Bool {
        if case .section = style { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            switch style {
            case .standalone:
                header
                commitBox

                /// One scroll view, around everything that can grow.
                ///
                /// It used to sit inside `workingTreeState`, around the
                /// changed files alone — so the branch review above them was
                /// a rigid sibling in this stack, and a review of 64 commits
                /// and 449 files made the panel taller than the pane. Nothing
                /// clipped it: the pane is centred in the sidebar, so the
                /// overflow split between the two ends and the top of the
                /// list was drawn over the pane switcher and under the
                /// window's traffic lights.
                ///
                /// The `GeometryReader` is what keeps the clean-tree
                /// placeholder centred in the pane. Inside a scroll view the
                /// proposed height is unbounded, so `maxHeight: .infinity`
                /// means nothing there; given the viewport's own height as a
                /// floor, the content is exactly as tall as the pane when
                /// there is little of it, and taller when there is more.
                GeometryReader { viewport in
                    ScrollView {
                        changeList
                            .frame(minHeight: viewport.size.height, alignment: .top)
                            .background(alignment: .top) { OverlayScrollers() }
                    }
                    /// Automatic, matching the file tree: the bar appears
                    /// while scrolling and fades, which is the only clue the
                    /// reader gets that there is more list below.
                    .scrollIndicators(.automatic)
                }

            case .section(let name, let isExpanded, let onToggle):
                sectionHeader(name: name, isExpanded: isExpanded, onToggle: onToggle)
                if isExpanded {
                    commitBox
                    changeList
                }
            }
        }
        // Once per repository rather than on every tab change: these three
        // are cheap next to `git status`, but they have no staleness guard
        // of their own, so asking for them on each refresh would spawn
        // three processes per repo per tick.
        .onAppear {
            center.requestStatus(root: root)
            center.requestBranches(root: root)
            center.requestStashes(root: root)
            center.requestLastCommit(root: root)
        }
        .sheet(isPresented: $isCreatingBranch) {
            GitBranchCreator { name in
                center.createBranch(named: name, in: root)
            }
        }
        .alert(
            "Discard changes?",
            isPresented: Binding(
                get: { !discarding.isEmpty },
                set: { if !$0 { discarding = [] } }
            )
        ) {
            Button("Discard", role: .destructive) {
                center.discard(discarding, in: root)
                discarding = []
            }
            Button("Cancel", role: .cancel) { discarding = [] }
        } message: {
            Text(discardWarning)
        }
        .alert("Undo the last commit?", isPresented: $isUndoingCommit) {
            Button("Undo Commit") { center.undoLastCommit(in: root) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(undoWarning)
        }
    }

    /// Not destructive — the changes come back staged — so this explains
    /// rather than warns. The one thing worth flagging is a commit that is
    /// already on the remote, where undoing locally puts the branch behind
    /// what everyone else has.
    private var undoWarning: String {
        let subject = center.lastCommits[root]
        let named = subject.map { "“\($0)” will be undone" } ?? "The last commit will be undone"
        let base = "\(named) and its changes put back as staged files."

        guard let status, status.hasUpstream, status.ahead == 0 else { return base }
        return base + "\n\nThis commit is already on the remote — undoing it here leaves your branch behind it."
    }

    // MARK: Headers

    private var header: some View {
        HStack(spacing: 6) {
            GitIcon(size: 12)

            Text(status?.branch ?? "—")
                .font(palette.font(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            syncCounts

            Spacer(minLength: 0)

            busyIndicator

            SidebarIconMenu(help: "Git Actions") { menuContents }
        }
        .foregroundStyle(.secondary)
        // The row is sized from the chip metrics like the change rows are,
        // so the menu's highlight has the same margin above and below it
        // that theirs do.
        .frame(height: SidebarIconChipMetrics.rowHeight)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.15), value: busy)
    }

    /// The disclosure row for a repository in a workspace.
    ///
    /// Carries the branch, the counts and the actions menu, so a repository
    /// can be pushed or pulled without expanding it — the reason the menu
    /// lives here rather than inside the body.
    private func sectionHeader(
        name: String,
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

                    Text(name)
                        .font(palette.font(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    GitIcon(size: 9)
                    Text(status?.branch ?? "—")
                        .font(palette.font(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    syncCounts

                    if let status, status.changeCount > 0 {
                        SidebarCountBadge(count: status.changeCount)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            busyIndicator

            SidebarIconMenu(help: "Git Actions") { menuContents }
        }
        .foregroundStyle(.secondary)
        .frame(height: SidebarIconChipMetrics.rowHeight)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .animation(.easeOut(duration: 0.15), value: busy)
    }

    /// Operations are silent by design, so this is the only sign one is
    /// running — and some of them (a pre-commit hook, a push) take long
    /// enough that without it the panel looks stuck rather than busy.
    @ViewBuilder
    private var busyIndicator: some View {
        if let busy {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text(busy)
                    .font(palette.font(size: 10))
                    .lineLimit(1)
            }
            .transition(.opacity)
        }
    }

    /// Commits to pull / to push, in the same capsule the group headers use
    /// for their terminal count — both are "how many of these are there",
    /// so they read as one idea rather than two conventions.
    @ViewBuilder
    private var syncCounts: some View {
        if let status, status.hasUpstream, status.ahead + status.behind > 0 {
            HStack(spacing: 4) {
                /// The counts are the buttons. A reader who has just read "3
                /// commits to pull" is already pointing at the thing they want
                /// to act on, and making them find the same action three
                /// levels into a menu is asking them to say it twice.
                if status.behind > 0 {
                    Button {
                        center.updateFromUpstream(in: root)
                    } label: {
                        SidebarCountBadge(count: status.behind, symbol: "arrow.down")
                    }
                    .buttonStyle(.plain)
                    .help("\(status.behind) commit\(status.behind == 1 ? "" : "s") to pull — "
                        + "click to update this branch")
                }
                if status.ahead > 0 {
                    Button {
                        center.push(in: root)
                    } label: {
                        SidebarCountBadge(count: status.ahead, symbol: "arrow.up")
                    }
                    .buttonStyle(.plain)
                    .help("\(status.ahead) commit\(status.ahead == 1 ? "" : "s") to push — "
                        + "click to push")
                }
            }
        }
    }

    @ViewBuilder
    private var menuContents: some View {
        if let status {
            if status.hasUpstream {
                Button("Push") { center.push(in: root) }
                Button("Pull") { center.pull(in: root) }
            } else if let branch = status.branch, !status.isDetached {
                Button("Publish Branch") { center.publish(branch: branch, in: root) }
            }
            Button("Fetch") { center.fetch(in: root) }

            Divider()

            Menu("Switch Branch") {
                ForEach(center.branches[root] ?? [], id: \.self) { branch in
                    Button {
                        center.checkout(branch: branch, in: root)
                    } label: {
                        if branch == status.branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                }
            }
            Button("Create Branch…") { isCreatingBranch = true }

            Divider()

            Button("Undo Last Commit…") { isUndoingCommit = true }

            Divider()

            Button("Stash Changes") { center.stashPush(message: nil, in: root) }
                .disabled(status.isClean)
            Button("Pop Stash") { center.stashPop(in: root) }
                .disabled((center.stashes[root] ?? []).isEmpty)

            Divider()

            Toggle("Amend Last Commit", isOn: $isAmending)
        }

        Button("Refresh") { center.requestStatus(root: root, force: true) }
    }

    // MARK: Commit

    private var commitBox: some View {
        VStack(spacing: 8) {
            TextField(
                "",
                text: $message,
                prompt: Text(isAmending ? "Amend message" : "Message"),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .font(palette.font(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )

            Button {
                commit()
            } label: {
                Text(commitTitle)
                    .font(palette.font(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent ?? .accentColor)
            .disabled(!canCommit)
        }
        .padding(.horizontal, 8)
        .padding(.top, isSection ? 6 : 0)
        .padding(.bottom, 8)
    }

    private var commitTitle: String {
        guard let status else { return "Commit" }
        if isAmending { return "Amend" }
        return status.staged.isEmpty ? "Commit All" : "Commit"
    }

    private var canCommit: Bool {
        guard busy == nil, let status else { return false }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return isAmending || !status.isClean
    }

    /// With nothing staged, commit everything — the shortcut VS Code
    /// offers. The staging is handed to the same operation rather than
    /// fired separately, so it can't race the commit for the busy lock.
    private func commit() {
        guard let status else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)

        center.commit(
            message: text,
            amend: isAmending,
            stageAll: !isAmending && status.staged.isEmpty,
            in: root
        )
        message = ""
        isAmending = false
    }

    // MARK: Changes

    /// The branch review, and under it the working tree's state.
    ///
    /// Two separate decisions here, and they were made at different times.
    ///
    /// **Outside the state switch**, which fixes a bug: the review used to
    /// live inside the `changes` case, so committing everything replaced it
    /// with "No changes" — and a clean tree is exactly when somebody wants it,
    /// because the work is committed and the question becomes what is about to
    /// go up. It belongs outside because it was never about the working tree.
    /// It is about commits, and a repository with nothing uncommitted still
    /// has every one of them.
    ///
    /// **Above the state, not below it**, which is where it started. Below
    /// reads better on paper — change files, commit, then review — and looks
    /// wrong: the placeholder for a clean tree takes the whole height, so the
    /// review ended up pinned to the bottom edge of the window with a screen
    /// of nothing above it. Collapsed it is one row, which is cheap to have
    /// near the top and unreachable at the bottom.
    @ViewBuilder
    private var changeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onOpenBranchDiff {
                GitBranchReviewView(
                    root: root,
                    onOpenReview: { editorCenter.showReview(.branch(root: root)) },
                    onOpenCommit: { commit in
                        editorCenter.showReview(.commit(
                            root: root,
                            sha: commit.sha,
                            subject: commit.subject))
                    },
                    onOpenDiff: { file, base in
                        onOpenBranchDiff(
                            URL(fileURLWithPath: root).appendingPathComponent(file.path),
                            base.ref
                        )
                    }
                )
            }

            workingTreeState
        }
    }

    @ViewBuilder
    private var workingTreeState: some View {
        switch GitPanelContent.resolve(status: status, hasLoaded: center.hasLoaded(root)) {
        case .loading:
            placeholder {
                ProgressView().controlSize(.small)
                Text("Reading repository…")
                    .font(palette.font(size: 10))
                    .foregroundStyle(.secondary)
            }
        case .unreadable:
            placeholder {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: isSection ? 13 : 18))
                Text("Couldn't read this repository")
                    .font(palette.font(size: 11))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        case .clean:
            placeholder {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: isSection ? 14 : 20))
                    .foregroundStyle(.tertiary)
                Text("No changes")
                    .font(palette.captionFont)
                    .foregroundStyle(.secondary)
            }
        case .changes:
            if let status {
                changeRows(status)
            }
        }
    }

    /// A placeholder fills the pane when this repository *is* the panel,
    /// and stays compact when it is one section among several — a
    /// full-height "No changes" per repo would push every other repository
    /// off the screen.
    private func placeholder<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(spacing: isSection ? 4 : 8) {
            content()
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: isSection ? nil : .infinity)
        .padding(isSection ? 10 : 16)
    }

    private func changeRows(_ status: GitStatus) -> some View {
        // A gap, so two adjacent rows' hover backgrounds never touch and
        // read as one block.
        LazyVStack(alignment: .leading, spacing: 2) {
            section("Merge Changes", status.unmerged, staged: false, merge: true)
            section("Staged Changes", status.staged, staged: true, merge: false)
            section("Changes", status.unstaged, staged: false, merge: false)

        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func section(
        _ title: String,
        _ changes: [GitFileChange],
        staged: Bool,
        merge: Bool
    ) -> some View {
        if !changes.isEmpty {
            HStack(spacing: 4) {
                Text(title)
                    .font(palette.font(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                SidebarCountBadge(count: changes.count)

                Spacer(minLength: 0)

                if !merge {
                    SidebarIconButton(help: staged ? "Unstage All" : "Stage All") {
                        if staged {
                            center.unstageAll(in: root)
                        } else {
                            stageAll()
                        }
                    } label: {
                        Image(systemName: staged ? "minus" : "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 4)
            .padding(.top, 6)

            ForEach(changes.map { SectionRow(change: $0, section: title) }) { row in
                GitChangeRow(
                    change: row.change,
                    staged: staged,
                    url: url(for: row.change),
                    isOpenInEditor: url(for: row.change).path
                        == editorCenter.tabs.selectedPath,
                    onOpen: { open(row.change) },
                    onPrimary: { toggleStage(row.change, staged: staged) },
                    onDiscard: merge ? nil : { discarding = [row.change] },
                    onOpenDiff: { openDiff(row.change) },
                    onOpenSource: { openSource(row.change) },
                    onIgnore: merge ? nil : { ignore(row.change) }
                )
            }
        }
    }

    private var discardWarning: String {
        guard let first = discarding.first else { return "" }
        if discarding.count == 1 {
            return first.isUntrackedOnly
                ? "\(first.name) will be deleted. This can't be undone."
                : "Changes to \(first.name) will be lost. This can't be undone."
        }
        return "Changes to \(discarding.count) files will be lost. This can't be undone."
    }

    // MARK: Actions

    /// Stages everything, after one question about everything that still holds
    /// markers.
    ///
    /// `GitCenter.stageAll(in:)` already refuses to `add -A` over a path git
    /// calls unmerged, and it keeps doing that — this is a second check in
    /// front of it, not a replacement. The two see different files: git stops
    /// calling a path unmerged as soon as it is staged once, so a file the
    /// reader resolved half of and staged is no longer unmerged and would go
    /// straight back into the index with its remaining `<<<<<<<` blocks.
    ///
    /// The paths are asked of `GitCenter` rather than read off `status` here,
    /// so the question is put about exactly the files the stage would touch.
    private func stageAll() {
        GitConflictStaging.confirmingAll(
            center.safePathsToStage(in: root),
            under: root,
            in: selectedTab?.window
        ) {
            center.stageAll(in: root)
        }
    }

    /// The one gesture that can end a merge badly, which is why staging goes
    /// through `GitConflictStaging` and unstaging does not: `git add` on a file
    /// with markers still in it tells git the conflict is resolved, and git's
    /// refusal to commit unmerged paths was the last thing in the way. Both the
    /// row's `+` button and the menu's Stage item arrive here, so guarding this
    /// guards both.
    private func toggleStage(_ change: GitFileChange, staged: Bool) {
        if staged {
            center.unstage([change.path], in: root)
        } else {
            GitConflictStaging.confirming(
                change,
                at: url(for: change),
                in: selectedTab?.window
            ) {
                center.stage([change.path], in: root)
            }
        }
    }

    /// Adds an untracked path to `.gitignore` and refreshes, so the row it
    /// was invoked from disappears rather than lingering as a change that is
    /// now ignored.
    ///
    /// Whether the path is a directory is asked of the filesystem rather than
    /// inferred from the name: git prints an untracked directory with a
    /// trailing slash, but not always, and a directory ignored as if it were
    /// a file leaves everything inside it still reported.
    private func ignore(_ change: GitFileChange) {
        let url = url(for: change)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        guard GitIgnore.add(
            relativePath: change.path,
            isDirectory: isDirectory.boolValue,
            inRepositoryAt: root
        ) else { return }

        center.requestStatus(root: root, force: true)
    }

    /// Git reports paths relative to the repository, so they have to be
    /// rejoined with the root before anything can open, reveal or copy them.
    private func url(for change: GitFileChange) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(change.path)
    }

    private func open(_ change: GitFileChange) {
        openThroughDialog(change, openInEditor: onOpenDiff ?? onOpenInEditor)
    }

    /// The diff, with no detour through the open dialog.
    ///
    /// The dialog answers "where do you want this file opened", and a terminal
    /// editor or an external app is a fine answer to that question and a wrong
    /// one to a menu item that names the diff.
    ///
    /// Falls back to the file when no host wired a diff, for the same reason
    /// `onOpenDiff` is optional: showing the file beats doing nothing.
    private func openDiff(_ change: GitFileChange) {
        guard let onOpenDiff else { return openSource(change) }
        onOpenDiff(url(for: change))
    }

    /// The file as it stands, wherever the reader has said files should open —
    /// the same question the file explorer asks, and the same answer.
    private func openSource(_ change: GitFileChange) {
        openThroughDialog(change, openInEditor: onOpenInEditor)
    }

    private func openThroughDialog(
        _ change: GitFileChange,
        openInEditor: @escaping (URL) -> Void
    ) {
        let url = url(for: change)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        FileOpener.prompt(
            for: url,
            in: selectedTab?.window,
            currentTerminal: surface(for: selectedTab),
            spawnTerminal: onSpawnTerminal,
            openInEditor: openInEditor
        )
    }

    private func surface(for tab: SidebarTabModel?) -> Ghostty.SurfaceView? {
        guard let controller = tab?.window?.windowController as? BaseTerminalController
        else { return nil }
        return controller.focusedSurface ?? controller.surfaceTree.root?.leftmostLeaf()
    }
}
