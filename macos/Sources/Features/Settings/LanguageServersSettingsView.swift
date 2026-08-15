import SwiftUI

/// Per-server configuration: which binary, what arguments, and raw
/// `initializationOptions` JSON — the knobs `LSPServerRegistry` used to be
/// the only word on.
///
/// One row per distinct binary (`LSPServerRegistry.distinctServers`)
/// rather than per language id: four of the ids in the registry are the
/// same TypeScript process, and a user who points that at a different
/// binary means all four, not one quarter of them.
///
/// Languages contributed by an extension sit in the same category sections
/// as the compiled-in ones, because to a reader looking for Elixir the
/// question is "where is Elixir", not "which of Phantom's two tables is it
/// in". What separates them is a badge — an extension's language can be
/// shadowed, unapproved, or asking for a build this one is not — and the
/// absence of an Install button, which is the one control here that turns a
/// string into `$SHELL -lic` and must never be reachable from a file
/// somebody dropped in a directory.
///
/// The editor's own completion preferences hang off the same screen rather
/// than a pane of their own, since "what completes, and when" is the same
/// question as "what server is running" seen from the other end.
///
/// Live per-file server status already lives in the editor's own banner,
/// scoped to the workspace that's actually open — a language can be
/// running in one window's root and crashed in another's, so a global
/// status row here would just be misleading. This view is only the
/// configuration half.
struct LanguageServersSettingsView: View {
    @State private var selection: LanguageServersSelection?
    @State private var searchText = ""
    @ObservedObject private var lsp = LSPCenter.shared
    @ObservedObject private var languages = LanguageResolver.shared

    /// Bumped whenever the detail pane writes something the sidebar shows.
    ///
    /// Two stores behind this screen write to `UserDefaults` and publish
    /// nothing: `LanguageTrustStore`, correctly, since a security record has
    /// no business driving a view's lifecycle, and the per-language
    /// completion table, because `@AppStorage` has no dictionary. So the
    /// detail pane tells the parent and both halves re-read. Without it the
    /// sidebar keeps saying "Refused", or "2 languages off", until the
    /// window is reopened — which is the same class of bug as a setting read
    /// once when a view was built.
    @State private var defaultsRevision = 0

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if showsEditorSection {
                            Section {
                                completionRow
                            } header: {
                                sectionHeader(title: "Editor", systemImage: "text.cursor", count: 1)
                            }
                        }

                        ForEach(sections) { section in
                            Section {
                                ForEach(section.rows) { row in
                                    languageRow(row)
                                }
                            } header: {
                                sectionHeader(
                                    title: section.category.title,
                                    systemImage: section.category.systemImage,
                                    count: section.rows.count
                                )
                            }
                        }

                        if sections.isEmpty, !showsEditorSection {
                            /// `verbatim` because the query is whatever the
                            /// reader typed, and the interpolating
                            /// initializer would run it through
                            /// `LocalizedStringKey` — so searching for
                            /// `*ts*` would echo back in italics.
                            Text(verbatim: "Nothing matches “\(searchText)”.")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 16)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
            .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)

            Divider()

            Group {
                switch selection {
                case .completion:
                    CompletionSettingsForm(
                        languages: languages.catalog,
                        onChange: { defaultsRevision += 1 }
                    )

                case .row(let id):
                    if let row = allRows.first(where: { $0.id == id }) {
                        detail(for: row)
                            .id(id)
                    } else {
                        /// The catalog reloaded and took the selected row with
                        /// it — an extension removed from the directory while
                        /// this screen was open.
                        placeholder
                    }

                case nil:
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Language Servers")
        .frame(minWidth: 720, minHeight: 420)
        // Opening this screen is the moment the answer matters, and it is
        // also the moment after which the user most often installs something
        // in the terminal next to it.
        .task { lsp.refreshInstalledCommands() }
    }

    @ViewBuilder
    private func detail(for row: LanguageRow) -> some View {
        switch row {
        case .server(let server):
            LanguageServerOverrideForm(server: server)

        case .contributed(let contributed):
            ContributedLanguageForm(
                contributed: contributed,
                trustRevision: defaultsRevision,
                onTrustChanged: { defaultsRevision += 1 }
            )
        }
    }

    private var placeholder: some View {
        Text("Select a language.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Rows

    /// Everything the sidebar can select, in one flat list, so the detail
    /// pane can resolve a selection by id rather than holding a copy of a
    /// value the catalog may have replaced underneath it.
    private var allRows: [LanguageRow] {
        LSPServerRegistry.distinctServers.map(LanguageRow.server)
            + languages.catalog.contributed.map(LanguageRow.contributed)
    }

    /// A row matches the query when any of the words a user would type to
    /// find it — its name, binary, language id, or file extensions —
    /// contains the query. A contributed row also matches on the extension
    /// that supplied it, which is often the only name the reader knows.
    /// Matching is case-insensitive.
    private var filteredRows: [LanguageRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allRows }
        let needle = query.lowercased()
        return allRows.filter { $0.haystack.lowercased().contains(needle) }
    }

    /// The rows, grouped by category, with sections in the category's
    /// declared order and empty sections dropped.
    private var sections: [LanguageServerSection] {
        var byCategory: [LSPServerCategory: [LanguageRow]] = [:]
        for row in filteredRows {
            byCategory[row.category, default: []].append(row)
        }
        return LSPServerCategory.allCases.compactMap { category in
            guard let rows = byCategory[category], !rows.isEmpty else { return nil }
            return LanguageServerSection(category: category, rows: rows)
        }
    }

    /// The Editor section survives a search only when the search is about
    /// it. It is one row and it is pinned to the top, so leaving it there
    /// under every query would make it read as a result for all of them.
    private var showsEditorSection: Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return "completion editor suggestions autocomplete".contains(query)
    }

    private var completionRow: some View {
        Button {
            selection = .completion
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Completion")
                        .lineLimit(1)
                    Text(completionSummary)
                        .font(.caption)
                        .foregroundStyle(selection == .completion ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(selection == .completion ? Color.accentColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    /// The subtitle under the Completion row, which has to be readable at a
    /// glance — the count of switched-off languages matters more than which
    /// they are, and "Off" has to be unmissable.
    private var completionSummary: String {
        guard CompletionSettingsStore.isEnabled else { return "Off" }
        let disabled = CompletionSettingsStore.byLanguage.values.filter { !$0 }.count
        guard disabled > 0 else { return "On" }
        return disabled == 1 ? "On · 1 language off" : "On · \(disabled) languages off"
    }

    private func languageRow(_ row: LanguageRow) -> some View {
        let isSelected = selection == .row(row.id)

        return Button {
            selection = .row(row.id)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                LanguageIconView(name: row.languageIconName)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        /// `verbatim` because a contributed row's name comes
                        /// out of a third-party file, and the interpolating
                        /// initializer treats its argument as a
                        /// `LocalizedStringKey` — markdown and all.
                        Text(verbatim: row.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        rowStatus(row)
                    }
                    Text(verbatim: row.subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func rowStatus(_ row: LanguageRow) -> some View {
        switch row {
        case .server(let server):
            LSPStatusIcon(status: lsp.status(for: server))

        case .contributed(let contributed):
            /// Recomputed rather than cached, and that is enough: the badge
            /// reads `LanguageTrustStore` directly, and `defaultsRevision`
            /// invalidating *this* view is what makes the read happen again
            /// after the detail pane forgets a decision.
            ContributedStatusIcon(status: ContributedStatus.of(contributed))
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText, prompt: Text("Search languages"))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private func sectionHeader(title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
            Spacer()
            Text(verbatim: "\(count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// What the sidebar has selected.
///
/// A case per kind rather than an `LSPServerDefinition?`, because the list
/// now holds three things that are not each other: a preferences screen, a
/// compiled-in server, and a language some file on disk contributed. The
/// contributed one is held **by id and not by value** so that a catalog
/// reload — an extension edited while this screen is open — leaves the
/// selection pointing at the new value rather than at a stale copy.
enum LanguageServersSelection: Hashable {
    case completion
    case row(String)
}

/// One selectable language, from either table.
private enum LanguageRow: Identifiable {
    case server(LSPServerDefinition)
    case contributed(LanguageCatalog.Contributed)

    /// Prefixed by kind, because a contributed language is free to name
    /// itself after a binary and nothing stops the two ids colliding.
    var id: String {
        switch self {
        case .server(let server): return "server:" + server.command
        case .contributed(let contributed): return "ext:" + contributed.id
        }
    }

    var category: LSPServerCategory {
        switch self {
        case .server(let server): return server.category
        case .contributed(let contributed): return contributed.language.category
        }
    }

    var displayName: String {
        switch self {
        case .server(let server): return server.displayName
        case .contributed(let contributed): return contributed.language.displayName
        }
    }

    /// The line under the name: what files this covers, and — for a
    /// contributed language — who supplied it, since that is the fact that
    /// tells the two kinds of row apart.
    var subtitle: String {
        switch self {
        case .server(let server):
            return LanguageRow.fileExtensions(sharing: server.command)

        case .contributed(let contributed):
            let types = contributed.language.fileExtensions.map { "." + $0 }
                + contributed.language.fileNames
            let name = contributed.extensionName.isEmpty
                ? contributed.listIdentity
                : contributed.extensionName
            guard !types.isEmpty else { return name }
            return types.joined(separator: ", ") + " · " + name
        }
    }

    var haystack: String {
        switch self {
        case .server(let server):
            return [
                server.displayName,
                server.command,
                server.languageID,
                LanguageRow.fileExtensions(sharing: server.command),
            ].joined(separator: " ")

        case .contributed(let contributed):
            return [
                contributed.language.displayName,
                contributed.language.languageID,
                contributed.language.server?.command ?? "",
                contributed.extensionName,
                contributed.publisher,
                contributed.language.fileExtensions.joined(separator: " "),
                contributed.language.fileNames.joined(separator: " "),
            ].joined(separator: " ")
        }
    }

    var languageIconName: String? {
        switch self {
        case .server(let server): return server.languageIconName
        case .contributed(let contributed):
            return LSPServerDefinition.iconName(forLanguageID: contributed.language.languageID)
        }
    }

    static func fileExtensions(sharing command: String) -> String {
        let extensionsByLanguage: [String: [String]] = [
            "typescript": ["ts"],
            "typescriptreact": ["tsx"],
            "javascript": ["js"],
            "javascriptreact": ["jsx"],
            "go": ["go", "mod", "sum"],
            "shellscript": ["sh", "bash", "zsh"],
            "markdown": ["md", "markdown"],
            "yaml": ["yaml", "yml"],
        ]
        var seen = Set<String>()
        return LSPServerRegistry.all
            .filter { $0.command == command }
            .flatMap { extensionsByLanguage[$0.languageID] ?? [$0.languageID] }
            .filter { seen.insert($0).inserted }
            .joined(separator: ", ")
    }
}

/// A category heading plus its rows, in display order.
private struct LanguageServerSection: Identifiable {
    let category: LSPServerCategory
    let rows: [LanguageRow]

    var id: LSPServerCategory { category }
}

/// One server's editable override, backed by `LSPServerOverrideStore`.
///
/// Split out from the list above so `.id(selection)` there forces a fresh
/// `@State` per server — without it, switching the sidebar selection would
/// keep editing the previous server's override in place, since SwiftUI
/// would otherwise reuse the same view identity and its state.
/// Whether the install/uninstall button is doing something, so its label
/// can swap for progress.
private enum ServerInstallOperation: Equatable {
    case none
    case installing
    case uninstalling
}

private struct LanguageServerOverrideForm: View {
    let server: LSPServerDefinition
    @ObservedObject private var lsp = LSPCenter.shared
    @State private var operation: ServerInstallOperation = .none
    @State private var operationError: String?
    @State private var operationOutput: [String] = []
    @State private var showUninstallConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                LanguageIconView(name: server.languageIconName, size: 26)
                Text(server.displayName)
                    .font(.title2.weight(.semibold))
                Spacer()
                operationButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Form {
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        LSPStatusBadge(status: lsp.status(for: server), detailed: true)
                    }

                    if let url = server.documentationURL {
                        Link(destination: url) {
                            Label("Documentation", systemImage: "book.closed")
                        }
                        .buttonStyle(.link)
                    }
                }

                Section {
                    CopyableValueRow(title: "Default Command", value: server.invocation)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(commandTitle)
                                .font(.headline)
                            Text(activeCommand)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let helper = server.installHelper {
                                Text(helper)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            if operation != .none, !operationOutput.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(recentOutput, id: \.self) { line in
                                        Text(line)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.top, 2)
                            }
                            if let operationError {
                                Text(operationError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer(minLength: 8)
                        CopyButton(text: activeCommand, label: "Copy")
                    }
                }

                ServerOverrideFields(
                    defaultCommand: server.command,
                    defaultArguments: server.arguments
                )
            }
            .formStyle(.grouped)
            .confirmationDialog(
                "Uninstall \(server.displayName)?",
                isPresented: $showUninstallConfirmation,
                titleVisibility: .visible
            ) {
                Button("Uninstall", role: .destructive) {
                    runOperation(.uninstalling)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Runs `\(server.uninstallCommand ?? "")` in a terminal with your login environment.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The install/uninstall button at the top of the screen. While an
    /// operation runs it becomes a progress bar — determinate once a
    /// percentage can be parsed from the live output, an indeterminate
    /// spinner before that.
    @ViewBuilder
    private var operationButton: some View {
        switch operation {
        case .installing, .uninstalling:
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(operationLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .none:
            if !lsp.hasProbedInstalls {
                // The probe runs off the main actor and lands in a moment.
                // Guessing "Install" until it does is how a user ends up
                // reinstalling something they already have.
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if isInstalled {
                Button(role: .destructive) {
                    showUninstallConfirmation = true
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
                .disabled(server.uninstallCommand == nil)
                .help(server.uninstallCommand == nil
                    ? "No automatic uninstall for this server."
                    : "Removes the server and its packages")
            } else {
                Button {
                    runOperation(.installing)
                } label: {
                    Label("Install", systemImage: "arrow.down.circle")
                }
                .help("Runs the install command in a terminal with your login environment")
            }
        }
    }

    /// Whether the server's binary is on disk, which is the only thing the
    /// Install/Uninstall choice is about.
    ///
    /// Not derived from the runtime status any more: a crashed server used
    /// to count as installed and a server uninstalled elsewhere kept
    /// offering to be uninstalled, because `error` is a fact about a process
    /// and this is a question about a file. The probe behind it is cached
    /// and resolved off the main actor — see `LSPCenter.installedCommands`.
    private var isInstalled: Bool { lsp.isInstalled(server) }

    /// Whether this row is offering removal rather than installation: the
    /// binary has to be there *and* have an automatic uninstall. gopls and
    /// the Xcode-bundled servers have neither an inverse nor any business
    /// being removed by us, so they keep offering their install command.
    private var showsUninstall: Bool {
        isInstalled && server.uninstallCommand != nil
    }

    /// The command the section shows and the copy button copies.
    private var activeCommand: String {
        guard showsUninstall, let uninstall = server.uninstallCommand else {
            /// Empty for a contributed server, which has no command this app
            /// may offer — see `installCommand`. The section around this is
            /// already hidden in that case; the fallback is here so a future
            /// caller that forgets gets nothing rather than something.
            return server.installCommand ?? ""
        }
        return uninstall
    }

    /// The heading over `activeCommand`, which has to name what that command
    /// does. Reading `isInstalled` instead put "Uninstall" over
    /// `go install golang.org/x/tools/gopls@latest`, and had Copy hand the
    /// user an install while promising the opposite.
    private var commandTitle: String {
        switch operation {
        case .none: return showsUninstall ? "Uninstall" : "Install"
        case .installing: return "Installing"
        case .uninstalling: return "Uninstalling"
        }
    }

    private var operationLabel: String {
        operation == .installing ? "Installing…" : "Uninstalling…"
    }

    /// The most recent live output lines while an operation runs, so the
    /// user sees real progress rather than an unexplained spinner.
    private var recentOutput: [String] {
        operationOutput.suffix(4).map { String($0) }
    }

    /// Best-effort percentage parsed from the live output. npm and
    /// Homebrew both print a running percentage while they work; before
    /// the first one arrives there is nothing to fill a determinate bar
    /// with, and the spinner shows instead.
    private var progress: Double? {
        for line in operationOutput.reversed() {
            guard let match = line.firstMatch(of: /(\d+(?:\.\d+)?)\s*%/),
                  let value = Double(match.output.1)
            else { continue }
            return min(max(value / 100.0, 0), 1)
        }
        return nil
    }

    /// Runs an install or uninstall through the user's login shell so
    /// `npm`, `brew`, `gem` — whichever the hint uses — are on `PATH`.
    /// Streams the output to the view as it arrives; the result lands back
    /// on the main actor.
    ///
    /// **Reachable only from a compiled-in definition.** The command comes
    /// from `LSPServerRegistry`, which is source in this build; a
    /// contributed language's form has no Install button at all, so nothing
    /// a manifest wrote can arrive at this `-lic`.
    private func runOperation(_ operation: ServerInstallOperation) {
        guard operation != .none else { return }
        let command = operation == .installing
            ? server.installCommand
            : server.uninstallCommand
        guard let command else { return }

        self.operation = operation
        operationError = nil
        operationOutput = []

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        Task { [self] in
            let environment = await Task.detached(priority: .userInitiated) {
                LoginEnvironment.executableEnvironment()
            }.value
            let result = await Task.detached(priority: .userInitiated) {
                ShellCommand.runStreaming(
                    shell,
                    ["-lic", command],
                    environment: environment,
                    timeout: 300
                ) { line in
                    DispatchQueue.main.async {
                        operationOutput.append(line)
                        if operationOutput.count > 12 {
                            operationOutput.removeFirst(operationOutput.count - 12)
                        }
                    }
                }
            }.value

            self.operation = .none
            if result.succeeded {
                LSPCenter.shared.noteAvailabilityChanged()
            } else {
                operationError = result.message
            }
        }
    }
}

/// The two editable override sections, shared by the built-in server form
/// and the contributed-language one.
///
/// Extracted rather than copied, because there is exactly one place a
/// user's override is written and a second pair of these `TextField`s would
/// be a second place for that write to drift. It is also the honest way to
/// give a contributed language "the same override form" without giving it
/// the Install button that happens to sit above it in the built-in one.
struct ServerOverrideFields: View {
    let defaultCommand: String
    let defaultArguments: [String]

    @State private var override: LSPServerOverride

    init(defaultCommand: String, defaultArguments: [String]) {
        self.defaultCommand = defaultCommand
        self.defaultArguments = defaultArguments
        _override = State(
            initialValue: LSPServerOverrideStore.override(for: defaultCommand) ?? LSPServerOverride()
        )
    }

    var body: some View {
        Group {
            Section {
                TextField("Command", text: $override.command, prompt: Text(verbatim: defaultCommand))
                TextField(
                    "Arguments",
                    text: $override.arguments,
                    prompt: Text(verbatim: defaultArguments.joined(separator: " "))
                )
            } header: {
                Text("Override")
            } footer: {
                Text(
                    """
                    Blank uses the default above. Takes effect the next \
                    time this server starts for a workspace — close and \
                    reopen a file of this kind, or relaunch Phantom.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $override.initializationOptionsJSON)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
            } header: {
                Text("initializationOptions (JSON)")
            } footer: {
                Text(
                    """
                    Sent to the server at startup. Left blank, Phantom's \
                    own resolution is used where it has one — Vue's \
                    TypeScript path today; every other server gets none.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onChange(of: override) { value in
            LSPServerOverrideStore.set(value, for: defaultCommand)
        }
    }
}

extension LSPServerDefinition {
    /// The asset name of the language's logo, or nil when the app ships no
    /// logo for this server's language.
    var languageIconName: String? {
        Self.iconName(forLanguageID: languageID)
    }

    /// Split off the instance property so a contributed language — which is
    /// not an `LSPServerDefinition` and may have no server at all — can
    /// borrow a logo when it happens to name a language this app ships one
    /// for. An extension contributing `elixir` gets the generic glyph;
    /// one contributing a second opinion about `ruby` gets the Ruby logo,
    /// which is the right answer either way.
    static func iconName(forLanguageID languageID: String) -> String? {
        let base: String
        switch languageID {
        case "typescript", "typescriptreact", "javascript", "javascriptreact":
            base = "ts-js"
        case "vue": base = "vue"
        case "swift": base = "swift"
        case "kotlin": base = "kotlin"
        case "python": base = "python"
        case "rust": base = "rust"
        case "go": base = "go"
        case "zig": base = "zig"
        case "json": base = "json"
        case "yaml": base = "yaml"
        case "shellscript": base = "bash"
        case "html": base = "html"
        case "css", "scss", "less": base = "css"
        case "java": base = "java"
        case "c": base = "c"
        case "cpp": base = "cpp"
        case "terraform": base = "terraform"
        case "php": base = "php"
        case "ruby": base = "ruby"
        case "markdown": base = "markdown"
        default: return nil
        }
        return "Lang-\(base)"
    }
}

/// A language's logo at a fixed size, so logos of any aspect ratio line up
/// across the list.
struct LanguageIconView: View {
    let name: String?
    var size: CGFloat = 18

    var body: some View {
        if let name {
            Image(name)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

private struct LSPStatusBadge: View {
    let status: LSPServerStatusSnapshot
    let detailed: Bool

    private var color: Color {
        switch status.state {
        case .running: return .green
        case .starting: return .orange
        case .error: return .red
        case .installed: return .blue
        case .unknown, .notInstalled: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.systemImage)
                .foregroundStyle(color)
            Text(status.label)
                .foregroundStyle(detailed ? .primary : (color == .secondary ? .secondary : color))
            if detailed, status.activeWorkspaceCount > 0 {
                // `verbatim` for the same reason the dev-server chip uses it:
                // interpolating a number into a `Text` goes through
                // `LocalizedStringKey`, which formats it for the locale — the
                // count would read "1.000" past a thousand, the way a port
                // number once read "4.201". The escaping was doubled here, so
                // the expression itself was being printed on screen.
                Text(verbatim: "· \(status.activeWorkspaceCount) workspace"
                    + (status.activeWorkspaceCount == 1 ? "" : "s"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .help(statusHelp)
    }

    private var statusHelp: String {
        if case .error(let message) = status.state { return message }
        return status.label
    }
}

private struct LSPStatusIcon: View {
    let status: LSPServerStatusSnapshot

    private var color: Color {
        switch status.state {
        case .running: return .green
        case .starting: return .orange
        case .error: return .red
        case .installed: return .blue
        case .unknown, .notInstalled: return .secondary
        }
    }

    var body: some View {
        Image(systemName: status.systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .help(status.label)
    }
}

struct CopyableValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(value)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            CopyButton(text: value, label: "Copy command")
        }
    }
}
