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

    private var selectedTab: SidebarTabModel? {
        tabManager.models.first { $0.isSelected }
    }

    private func surface(for tab: SidebarTabModel?) -> Ghostty.SurfaceView? {
        guard let controller = tab?.window.windowController as? BaseTerminalController
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

    /// The directory to show beside a name, and only when it is needed.
    ///
    /// Search results are a flat list, so two files called `index.ts` are two
    /// identical rows — the one thing the list must not be. The folder is
    /// shown for those and left off everywhere else, because a path repeated
    /// on every row is noise that makes the ambiguous case harder to spot,
    /// not easier.
    private func ghostPath(for row: FileRow) -> String? {
        guard let matches = model.matches, let root = model.root else { return nil }
        guard matches.contains(where: { $0.id != row.id && $0.node.name == row.node.name })
        else { return nil }

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
                    proxy.scrollTo(path, anchor: .center)
                }
            }
            .onChange(of: model.editing) { _ in
                guard let id = model.createPlaceholderID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // A create field lands at the end of a possibly long folder, so
            // it can start below the fold; make sure the keys the explorer
            // answers for have somewhere to land.
            .onChange(of: model.editing) { editing in
                if editing != nil { treeFocused = true }
            }
            .focusable()
            .focused($treeFocused)
            .backport.onKeyPress { press in handleKeyPress(press) }
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

        FileOpener.prompt(
            for: row.node.url,
            in: selectedTab?.window,
            currentTerminal: surface(for: selectedTab),
            spawnTerminal: onSpawnTerminal,
            openInEditor: onOpenInEditor
        )
    }

    /// The keys the explorer answers for while it has focus: the configured
    /// create shortcuts, Return to rename the selection, Delete to trash it.
    private func handleKeyPress(_ press: BackportKeyPress) -> BackportKeyPressResult {
        guard model.editing == nil else { return .ignored }
        let modifiers = PhantomShortcut.modifiers(from: press.modifiers)

        if shortcuts.newFile.matches(modifiers: modifiers, key: press.key) {
            model.beginCreateDefault(isFolder: false)
            return .handled
        }
        if shortcuts.newFolder.matches(modifiers: modifiers, key: press.key) {
            model.beginCreateDefault(isFolder: true)
            return .handled
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

    private func commitRename(_ row: FileRow, to name: String) {
        let result = model.commitRename(path: row.node.path, to: name)
        if case .success(let target) = result, target.path != row.node.path {
            editorCenter.repath(from: row.node.path, to: target.path)
        }
        treeFocused = true
    }

    private func commitCreate(parent: String, isFolder: Bool, name: String) {
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

    /// Moves dropped items into a folder: the tree background into the root,
    /// a folder row into that folder.
    private func handleDrop(_ urls: [URL], into directory: String) {
        guard !directory.isEmpty else { return }
        for url in urls where url.isFileURL {
            let result = model.move(path: url.path, into: directory)
            if case .success(let target) = result, target.path != url.path {
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
    private var isCreateField: Bool { row.isCreatePlaceholder }

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

    private var content: some View {
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
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .contextMenu { menu }
        .help(row.node.path)
        .draggable(row.node.url)
        .dropDestination(for: URL.self) { urls, _ in
            onDropInto(urls)
            return true
        }
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

    private func commit() {
        if isCreateField, case .create(let parent, let isFolder) = editing {
            onCommitCreate(parent, isFolder, draftName)
        } else {
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

    private var background: Color {
        // The item being acted on reads strongest, then the file on screen,
        // then the terminal's directory. Hover stays the faintest so it
        // never competes with a real state.
        if isSelected { return accent.opacity(0.45) }
        if isOpenInEditor { return accent.opacity(0.34) }
        if isCurrent { return accent.opacity(0.28) }
        return isHovered ? accent.opacity(0.12) : .clear
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
