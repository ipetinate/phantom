import AppKit
import Combine
import SwiftUI

/// The file explorer panel: the workspace tree for whichever terminal is
/// selected.
struct FileExplorerView: View {
    @ObservedObject var tabManager: SidebarTabManager
    @ObservedObject var store: SidebarGroupStore

    /// Opens a terminal beside the selected one; every file opened here
    /// gets its own. See `FileOpener.openInTerminal`.
    var onSpawnTerminal: () -> Ghostty.SurfaceView? = { nil }

    /// Opens the file in this window's editor pane.
    var onOpenInEditor: (URL) -> Void = { _ in }

    /// The pane's open files, so the tree can say which one is on screen.
    ///
    /// Without it the only highlighted row was the terminal's working
    /// directory, and a reader looking at a file had no way to tell which of
    /// forty names in the tree it was.
    @ObservedObject var editorCenter: EditorCenter

    @StateObject private var model = FileExplorerModel()
    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var icons: FileIconProvider = .shared
    @ObservedObject private var refresh: FileExplorerRefresh = .shared
    @ObservedObject private var shortcuts: PhantomShortcutStore = .shared

    /// Whether the tree owns the keyboard. Keys like Return and Delete only
    /// mean rename and trash while the explorer is the one being typed at.
    @FocusState private var treeFocused: Bool

    /// The path waiting for the "Move to Trash" confirmation.
    @State private var pendingDelete: String?

    /// The file a reveal still owes a scroll to, or nil when nothing is
    /// pending.
    ///
    /// Held for one reason: a row inside a folder that had never been listed
    /// does not exist yet, and the listing lands off the main actor a moment
    /// later. Cleared as soon as the scroll happens, which is what keeps the
    /// reveal an event — a folder the reader collapses afterwards stays
    /// collapsed, because nothing remembers it was ever revealed.
    @State private var revealTarget: String?

    private var selectedTab: SidebarTabModel? {
        tabManager.models.first { $0.isSelected }
    }

    private func surface(for tab: SidebarTabModel?) -> Ghostty.SurfaceView? {
        guard let controller = tab?.window?.windowController as? BaseTerminalController
        else { return nil }
        return controller.focusedSurface ?? controller.surfaceTree.root?.leftmostLeaf()
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.root == nil {
                empty
            } else {
                search
                tree
            }
        }
        .onAppear {
            model.onRootModeChanged = syncRoot
            syncRoot()
        }
        .onChange(of: tabManager.groupingVersion) { _ in syncRoot() }
        .onChange(of: refresh.token) { _ in model.reloadVisible() }
        .onReceive(
            Publishers.MergeMany(tabManager.models.map { $0.objectWillChange })
        ) { _ in
            DispatchQueue.main.async { syncRoot() }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("You can restore it from the Trash later.")
        }
        .alert(
            "Couldn't do that",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var deleteTitle: String {
        guard let pendingDelete else { return "Move to the Trash?" }
        return "Move “\((pendingDelete as NSString).lastPathComponent)” to the Trash?"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            Text(model.root?.lastPathComponent ?? "No Folder")
                .font(palette.font(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 0)

            SidebarIconMenu(help: "New File or Folder", icon: "plus") {
                Button("New File") { model.beginCreateDefault(isFolder: false) }
                Button("New Folder") { model.beginCreateDefault(isFolder: true) }
            }

            SidebarIconMenu(help: model.rootMode.detail) {
                Picker("Root", selection: $model.rootMode) {
                    ForEach(WorkspaceRootMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Toggle("Show Hidden Files", isOn: $model.showHiddenFiles)

                if !icons.themes.isEmpty {
                    Menu("Icon Theme") {
                        Button("SF Symbols") {
                            icons.select(FileIconProvider.symbolsOnly)
                        }
                        Divider()
                        ForEach(icons.themes, id: \.name) { theme in
                            Button(theme.name.capitalized) { icons.select(theme.name) }
                                .disabled(!theme.isSupported)
                        }
                    }
                }

                Divider()

                Button("Choose Editor App…") {
                    FileOpener.chooseApp(in: NSApp.keyWindow) { _ in }
                }
                if FileOpener.preferredApp != nil {
                    Button("Forget Editor App") { FileOpener.clearPreferredApp() }
                }
            }
        }
        .foregroundStyle(.secondary)
        // Sized from the chip metrics, same as the Git panel's header, so
        // the two panels' menus sit at the same height and their
        // highlights keep the same margin.
        .frame(height: SidebarIconChipMetrics.rowHeight)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("No folder for this terminal")
                .font(palette.captionFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: Tree

    /// The search field, always there.
    ///
    /// No submit button and no disclosure: a field you have to reveal before
    /// you can use it is a field you forget exists, and one you have to press
    /// Return in makes you wait to find out you typed the wrong thing. It
    /// filters as you type, debounced in the model.
    private var search: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            TextField("Search files", text: $model.filter)
                .textFieldStyle(.plain)
                .font(palette.font(size: 11))

            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else if !model.filter.isEmpty {
                Button {
                    model.filter = ""
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

    /// The directory to show beside a name, on every search result.
    ///
    /// It used to appear only where two matches shared a name, on the theory
    /// that a path on every row is noise. Using it says otherwise: a flat
    /// list of names strips the one thing that tells you *which* file you are
    /// about to open, and having to notice a collision before the folder
    /// appears means the reader is doing the disambiguating the list was
    /// meant to do. Repeated paths read as a column; a path that comes and
    /// goes reads as a glitch.
    ///
    /// Still search-only. The tree already shows where a file is by where it
    /// sits, so a folder name beside it there would be saying it twice.
    private func ghostPath(for row: FileRow) -> String? {
        guard model.matches != nil, let root = model.root else { return nil }

        let directory = (row.node.path as NSString).deletingLastPathComponent
        guard directory.hasPrefix(root.path) else { return directory }
        let relative = String(directory.dropFirst(root.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? nil : relative
    }

    /// The rows to show: matches while searching, the tree otherwise.
    private var visibleRows: [FileRow] {
        model.matches ?? model.rows
    }

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let matches = model.matches, matches.isEmpty, !model.isSearching {
                        Text("No files match \"\(model.filter)\"")
                            .font(palette.font(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }

                    ForEach(visibleRows) { row in
                        FileExplorerRow(
                            row: row,
                            editing: model.editing,
                            isExpanded: model.isExpanded(row.node),
                            isCurrent: row.node.path == model.currentDirectory,
                            isSelected: row.node.path == model.selection,
                            ghostPath: ghostPath(for: row),
                            isOpenInEditor: row.node.path == editorCenter.tabs.selectedPath,
                            onTap: { handleTap(row) },
                            onBeginRename: { model.beginRename(path: row.node.path) },
                            onCommitRename: { name in commitRename(row, to: name) },
                            onCommitCreate: { parent, isFolder, name in
                                commitCreate(parent: parent, isFolder: isFolder, name: name)
                            },
                            onCancelEdit: { model.cancelEditing() },
                            onDelete: { requestDelete(row.node.path) },
                            onCreateFile: { model.beginCreate(in: row.node.path, isFolder: false) },
                            onCreateFolder: { model.beginCreate(in: row.node.path, isFolder: true) },
                            onDropInto: { urls in handleDrop(urls, into: row.node.path) }
                        )
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
                .background(alignment: .top) { OverlayScrollers() }
            }
            // Automatic rather than hidden: the bar should appear while
            // scrolling and go away after, which is what overlay scrollers
            // do — hiding it outright loses the only clue about how much
            // tree there is below.
            .scrollIndicators(.automatic)
            .onChange(of: model.currentDirectory) { path in
                guard let path else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    /// No anchor: `scrollTo` then moves the least it can to
                    /// bring the row into view, and leaves the list alone when
                    /// the row is already there. Centring instead re-scrolled
                    /// on every change, which is what made a click feel
                    /// mechanical — the row you aimed at jumped to the middle
                    /// under the pointer.
                    proxy.scrollTo(path)
                }
            }
            .onChange(of: model.editing) { _ in
                guard let id = model.createPlaceholderID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    /// Centred, unlike the others: a name field that opens
                    /// at the very bottom of a long folder is half off screen
                    /// with a minimal scroll, and there is nothing to preserve
                    /// about a position the reader is about to type into.
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: editorCenter.tabs.selectedPath) { path in
                revealOpenFile(path, using: proxy)
            }
            .onChange(of: model.rows) { _ in
                guard let target = revealTarget else { return }
                scrollToReveal(target, using: proxy)
            }
            /// Clearing the search is what pays the scroll a search deferred.
            /// Watched as a `Bool` rather than on the matches themselves: the
            /// question is only whether the tree is back, and every keystroke
            /// in that field rebuilds the array.
            .onChange(of: model.matches == nil) { isTree in
                guard isTree, let target = revealTarget else { return }
                scrollToReveal(target, using: proxy)
            }
            // A create field lands at the end of a possibly long folder, so
            // it can start below the fold; make sure the keys the explorer
            // answers for have somewhere to land.
            .onChange(of: model.editing) { editing in
                if editing != nil { treeFocused = true }
            }
            .focusable()
            .focused($treeFocused)
            // Focusable for the keys, without the ring: selecting a file put
            // a blue outline around the entire tree, which reads as the list
            // being a control you are editing rather than a place you are
            // looking at. The selected row already says where focus is.
            .backport.focusEffectDisabled()
            .backport.onKeyPress { press in handleKeyPress(press, using: proxy) }
            .dropDestination(for: URL.self) { urls, _ in
                handleDrop(urls, into: model.root?.path ?? "")
                return true
            }
        }
    }

    // MARK: Actions

    private func handleTap(_ row: FileRow) {
        guard !row.isTruncationNotice else { return }
        model.select(row.node.path)
        treeFocused = true

        if row.node.isDirectory {
            model.toggle(row.node)
            return
        }

        openFile(row.node.url)
    }

    /// Opens a file the same way whether a click or Space asked for it.
    ///
    /// Shared rather than repeated because "the same action a click performs"
    /// is the whole specification of Space here: this decides nothing itself,
    /// so the destination setting, the app fallback and the terminal it lands
    /// beside can only ever be answered once.
    private func openFile(_ url: URL) {
        FileOpener.prompt(
            for: url,
            in: selectedTab?.window,
            currentTerminal: surface(for: selectedTab),
            spawnTerminal: onSpawnTerminal,
            openInEditor: onOpenInEditor
        )
    }

    /// Opens the folders holding the file the pane just switched to, and
    /// scrolls its row into view.
    ///
    /// Answers the *change* of open file, never the file that is open: the
    /// highlight can only be seen if the row is on screen, and a reveal that
    /// ran on every redraw would re-open a folder the reader had deliberately
    /// collapsed, which is a worse thing than an unseen highlight.
    ///
    /// While a search is on, the list on screen is matches rather than the
    /// tree, so scrolling one of those into view would say nothing about
    /// where the file lives. The folders open anyway, so clearing the search
    /// — which is how most files reached from a search get opened — finds
    /// the tree already standing open at the right place.
    private func revealOpenFile(_ path: String?, using proxy: ScrollViewProxy) {
        revealTarget = nil
        guard let path else { return }

        model.expandAncestors(of: path)

        /// Set before the search is considered, so a file opened from a search
        /// result has its scroll owed rather than skipped. `scrollToReveal`
        /// declines to act while matches are on screen and is called again the
        /// moment they go.
        revealTarget = path
        scrollToReveal(path, using: proxy)
    }

    /// Scrolls to the file a reveal is waiting on, a runloop turn later.
    ///
    /// Never in the same turn: a row inside a folder that just opened does
    /// not exist until the rebuilt list has been through a render, and
    /// `scrollTo` an id the list doesn't hold does nothing at all. A folder
    /// that had never been listed takes longer than a turn — its rows arrive
    /// with the listing, off the main actor — which is why `rows` changing
    /// calls this again.
    ///
    /// The target is dropped once nothing is listing and the row still isn't
    /// there: a folder that couldn't be read yields no children and no row,
    /// and a file outside the tree never had one. Waiting forever would let
    /// an unrelated expansion, minutes later, jump the tree somewhere the
    /// reader didn't ask to go.
    ///
    /// A search does not drop it, it defers it. While the field has text the
    /// list on screen is matches rather than tree rows, so there is nothing to
    /// scroll to — but clicking a result is the single most common way a file
    /// deep in a tree gets opened, and the tree is where the reader looks
    /// next. So the target waits, and clearing the field spends it.
    private func scrollToReveal(_ target: String, using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            guard revealTarget == target else { return }
            /// Kept, not cleared: the scroll is owed until the tree is what
            /// is on screen again. See `revealPendingTargetWhenSearchClears`.
            guard model.matches == nil else { return }
            guard model.rows.contains(where: { $0.id == target }) else {
                if model.loading.isEmpty { revealTarget = nil }
                return
            }

            revealTarget = nil
            /// Minimal, for the reason on `currentDirectory` above: a reveal
            /// should put the row on screen, not rearrange the list around it.
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target)
            }
        }
    }

    /// The keys the explorer answers for while it has focus: the arrows and
    /// Space to walk the tree, the configured create shortcuts, Return to
    /// rename the selection, Delete to trash it.
    private func handleKeyPress(
        _ press: BackportKeyPress,
        using proxy: ScrollViewProxy
    ) -> BackportKeyPressResult {
        guard model.editing == nil else { return .ignored }
        let modifiers = PhantomShortcut.modifiers(from: press.modifiers)

        /// Resolved against the whole map rather than the two explorer
        /// commands, so a combination the reader gave to an editor command
        /// falls through to the editor instead of being swallowed here.
        switch shortcuts.map.action(key: press.key, modifiers: modifiers) {
        case .newFile:
            model.beginCreateDefault(isFolder: false)
            return .handled
        case .newFolder:
            model.beginCreateDefault(isFolder: true)
            return .handled
        default:
            break
        }

        /// Bare keys only. An arrow carries the function-key flag and nothing
        /// else here, so `modifiers` — already narrowed to the four a shortcut
        /// can hold — is empty for the presses this owns, and ⇧⌥↑ goes on
        /// reaching the editor's Move Line Up.
        if modifiers.isEmpty, let key = FileTreeNavigation.Key(character: press.key) {
            return navigate(key, using: proxy)
        }

        if press.key == KeyEquivalent.return.character {
            guard let selection = model.selection else { return .ignored }
            model.beginRename(path: selection)
            return .handled
        }
        if press.key == KeyEquivalent.delete.character {
            guard let selection = model.selection else { return .ignored }
            requestDelete(selection)
            return .handled
        }
        return .ignored
    }

    /// Walks the tree: `FileTreeNavigation` decides, this spends the answer.
    ///
    /// The rows handed over are the ones on screen — matches while a search is
    /// on — because every one of these keys is about what the reader can see.
    private func navigate(
        _ key: FileTreeNavigation.Key,
        using proxy: ScrollViewProxy
    ) -> BackportKeyPressResult {
        let navigation = FileTreeNavigation(
            rows: visibleRows,
            expanded: model.expanded,
            selection: model.selection
        )

        switch navigation.command(for: key) {
        case .nothing:
            break
        case .select(let path):
            model.select(path)
            /// Unanimated, unlike every other scroll here: a held arrow key
            /// repeats every few dozen milliseconds, and a fifth of a second
            /// of easing per step leaves the list trailing the row it is
            /// supposed to be following. Minimal for the reason on
            /// `currentDirectory` — a step through a list should move it as
            /// little as it takes to see the row.
            proxy.scrollTo(path)
        case .expand(let node), .collapse(let node):
            model.toggle(node)
        case .open(let node):
            openFile(node.url)
        }

        /// Handled even when nothing moved. These keys belong to the tree
        /// while the tree has focus, and letting a clamped ↓ through would
        /// scroll the list out from under the selection the reader is
        /// stepping through — the one thing they are watching.
        return .handled
    }

    /// Both commits ask the model whether the edit they belong to is still
    /// the live one.
    ///
    /// A field's focus loss arrives after the row it belonged to is gone, so
    /// a cancelled create and an already-committed rename can each deliver
    /// one more commit — against a placeholder that was never written, or a
    /// name that has already moved. The row only knows what it was told when
    /// it was last drawn; the model knows what is being asked for now.
    private func commitRename(_ row: FileRow, to name: String) {
        guard model.isEditing(.rename(path: row.node.path)) else { return }

        let result = model.commitRename(path: row.node.path, to: name)
        if case .success(let target) = result, target.path != row.node.path {
            editorCenter.repath(from: row.node.path, to: target.path)
        }
        treeFocused = true
    }

    private func commitCreate(parent: String, isFolder: Bool, name: String) {
        guard model.isEditing(.create(parent: parent, isFolder: isFolder)) else { return }

        model.commitCreate(parent: parent, isFolder: isFolder, name: name)
        treeFocused = true
    }

    private func requestDelete(_ path: String) {
        guard model.editing == nil else { return }
        pendingDelete = path
    }

    private func confirmDelete() {
        guard let path = pendingDelete else { return }
        pendingDelete = nil
        if case .success = model.delete(path: path) {
            editorCenter.didDelete(path: path)
        }
        treeFocused = true
    }

    /// Takes dropped items into a folder: the tree background into the root,
    /// a folder row into that folder.
    ///
    /// Only a move carries an open tab with it — see
    /// `FileExplorerModel.drop(path:into:)` for which drags move and which
    /// copy.
    private func handleDrop(_ urls: [URL], into directory: String) {
        guard !directory.isEmpty else { return }
        for url in urls where url.isFileURL {
            let result = model.drop(path: url.path, into: directory)
            if case .success(.moved(let target)) = result, target.path != url.path {
                editorCenter.repath(from: url.path, to: target.path)
            }
        }
    }

    /// Recomputes the root from the selected terminal, then points the
    /// highlight at wherever that terminal currently is.
    private func syncRoot() {
        let tab = selectedTab

        var groupRoot: String?
        if let tab,
           let group = store.resolveGroup(surfaceId: tab.surfaceId, pwd: tab.pwd),
           case .project(let root) = group.kind {
            groupRoot = root
        }

        model.setRoot(WorkspaceRootResolver.resolve(
            mode: model.rootMode,
            groupRoot: groupRoot,
            repoRoot: tab?.repoRoot,
            pwd: tab?.pwd
        ))
        model.reveal(tab?.pwd)
    }
}

/// One row of the tree.
private struct FileExplorerRow: View {
    let row: FileRow

    /// What the explorer is asking for a name for, if anything — lets this
    /// row know whether it is the one showing a field.
    let editing: FileEditState?
    let isExpanded: Bool
    let isCurrent: Bool
    let isSelected: Bool

    /// The containing folder, shown only when the name alone is ambiguous.
    let ghostPath: String?

    /// The file showing in the pane right now.
    ///
    /// Only this one is marked. Marking every open file as well turned the
    /// tree into a wall of highlight that answered a question nobody asked —
    /// the tab bar already says what is open, and the point of this mark is
    /// "here is where you are".
    let isOpenInEditor: Bool
    let onTap: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCommitCreate: (String, Bool, String) -> Void
    let onCancelEdit: () -> Void
    let onDelete: () -> Void
    let onCreateFile: () -> Void
    let onCreateFolder: () -> Void
    let onDropInto: ([URL]) -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var icons: FileIconProvider = .shared
    @State private var isHovered = false

    /// What the rename/create field holds while it is open.
    @State private var draftName = ""
    @State private var draftSelection: Range<String.Index>?
    @FocusState private var fieldFocused: Bool

    private var accent: Color { palette.accent ?? .accentColor }

    private var isRenaming: Bool { editing == .rename(path: row.node.path) }

    /// True only while the model is still asking for this name.
    ///
    /// Derived from `editing` rather than from the row alone: a placeholder
    /// row keeps saying it is one after Esc, and the field's focus loss then
    /// arrives at a `commit()` that took itself for a rename — of a file
    /// that was never created.
    private var isCreateField: Bool {
        guard row.isCreatePlaceholder, case .create(let parent, _) = editing else { return false }
        return parent == (row.node.path as NSString).deletingLastPathComponent
    }

    var body: some View {
        if row.isTruncationNotice {
            notice
        } else if isRenaming || isCreateField {
            field
        } else {
            content
        }
    }

    private var notice: some View {
        Text(row.node.name)
            .font(palette.font(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.leading, indent + 18)
            .padding(.vertical, 3)
    }

    /// Only a folder can be dropped into.
    ///
    /// The drop target used to be every row, so releasing a drag half a row
    /// low asked the filesystem to move a file *inside* another file and
    /// surfaced whatever `FileManager` said about that — an error message
    /// about a gesture the tree should never have accepted in the first
    /// place.
    @ViewBuilder
    private var content: some View {
        if row.node.isDirectory {
            label.dropDestination(for: URL.self) { urls, _ in
                onDropInto(urls)
                return true
            }
        } else {
            label
        }
    }

    private var label: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                disclosure
                FileIconView(icon: icon)
                Text(row.node.name)
                    .font(palette.font(
                        size: 11,
                        weight: isCurrent || isOpenInEditor || isSelected ? .semibold : .regular
                    ))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let ghostPath {
                    Text(ghostPath)
                        .font(palette.font(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        // Truncated from the front: the folder nearest the
                        // file is the part that tells two of them apart.
                        .truncationMode(.head)
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, indent)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selectionRing, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .contextMenu { menu }
        .help(row.node.path)
        .draggable(row.node.url)
    }

    /// The row drawn while a name is being given: the text field that
    /// replaces the label, and nothing else that can swallow a key.
    private var field: some View {
        HStack(spacing: 4) {
            disclosure
            FileIconView(icon: icon)
            BackportSelectionTextField("", text: $draftName, selection: $draftSelection)
                .textFieldStyle(.plain)
                .font(palette.font(size: 11))
                .focused($fieldFocused)
                .onAppear { startEditing() }
                .onSubmit { commit() }
                .onExitCommand { cancel() }
                .onChange(of: fieldFocused) { focused in
                    guard !focused else { return }
                    if isRenaming || isCreateField { commit() }
                }
            Spacer(minLength: 0)
        }
        .padding(.leading, indent)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(accent.opacity(0.45))
        )
    }

    /// Puts the field into "type to replace the base name" state: focus it
    /// and select everything up to the extension, the way Finder does.
    private func startEditing() {
        draftName = row.node.name
        fieldFocused = true
        DispatchQueue.main.async {
            draftSelection = Self.baseNameRange(in: draftName, isFolder: row.node.isDirectory)
        }
    }

    /// Commits whichever edit this row is showing, and nothing when it is
    /// showing none — the `else` that used to fall through to a rename is
    /// how a cancelled create ended up renaming a file that never existed.
    private func commit() {
        if isCreateField, case .create(let parent, let isFolder) = editing {
            onCommitCreate(parent, isFolder, draftName)
        } else if isRenaming {
            onCommitRename(draftName)
        }
    }

    private func cancel() {
        onCancelEdit()
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.node.isDirectory {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
        } else {
            Color.clear.frame(width: 10, height: 1)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if row.node.isDirectory {
            Button("New File") { onCreateFile() }
            Button("New Folder") { onCreateFolder() }
            Divider()
        }
        Button("Rename") { onBeginRename() }
        Button("Delete") { onDelete() }
            .foregroundStyle(.red)
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([row.node.url])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.node.path, forType: .string)
        }
    }

    private var icon: FileIcon {
        row.node.isDirectory
            ? icons.icon(forFolder: row.node.name, expanded: isExpanded)
            : icons.icon(forFile: row.node.name)
    }

    /// One filled row, and it is the file open in the focused tab.
    ///
    /// There used to be three fills at three strengths — the clicked row, the
    /// open file, and the terminal's directory — and two of them could land on
    /// different rows at once. Reading that took working out which shade meant
    /// what, which is a puzzle nobody asked for in a file list: the question a
    /// tree answers is "where am I", and there is one answer.
    ///
    /// The other two states did not go away, they stopped being fills.
    /// Selection is drawn as an outline, because it is a *different* fact —
    /// what Return renames and Delete trashes — and the terminal's directory
    /// keeps the bolder text it already had.
    private var background: Color {
        switch emphasis.fill {
        case .open: accent.opacity(0.45)
        case .hover: accent.opacity(0.12)
        case .none: .clear
        }
    }

    private var emphasis: FileExplorerRowEmphasis {
        .resolve(
            isOpenInEditor: isOpenInEditor,
            isSelected: isSelected,
            isHovered: isHovered
        )
    }

    /// The selection, as a ring rather than a fill.
    ///
    /// It cannot simply be dropped: Return renames it, Delete moves it to the
    /// trash, and a new file lands beside it — three commands read
    /// `model.selection`, so a tree with no selection is a tree where those
    /// three have nothing to act on. What it must stop doing is competing with
    /// the open file for the same visual language, which is what put two
    /// highlights on screen.
    ///
    /// Nothing is drawn when the selection *is* the open file, the common case
    /// after a click: a ring around the filled row would be a second mark for
    /// one fact.
    private var selectionRing: Color {
        emphasis.showsSelectionRing ? accent.opacity(0.55) : .clear
    }

    private var indent: CGFloat {
        CGFloat(row.depth) * 12
    }

    /// The range to select when a name field opens: the whole name for a
    /// folder, everything before the extension for a file, so typing
    /// replaces just the meaningful part.
    private static func baseNameRange(in name: String, isFolder: Bool) -> Range<String.Index>? {
        let length = isFolder ? (name as NSString).length : (name as NSString).deletingPathExtension.count
        let nsRange = NSRange(location: 0, length: length)
        return Range(nsRange, in: name)
    }
}
