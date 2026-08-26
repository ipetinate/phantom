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
/// Live per-file server status already lives in the editor's own banner,
/// scoped to the workspace that's actually open — a language can be
/// running in one window's root and crashed in another's, so a global
/// status row here would just be misleading. This view is only the
/// configuration half.
struct LanguageServersSettingsView: View {
    /// The selected row, held **by id and not by value**, so that a
    /// catalog reload — an extension edited while this screen is open —
    /// leaves the selection pointing at the new value rather than at a
    /// stale copy of the old one.
    @State private var selection: String?
    @State private var searchText = ""
    @ObservedObject private var lsp = LSPCenter.shared
    @ObservedObject private var languages = LanguageResolver.shared
    @ObservedObject private var navigation = SettingsNavigation.shared

    /// Bumped whenever the detail pane writes something the sidebar shows.
    ///
    /// `LanguageTrustStore` writes to `UserDefaults` and publishes nothing,
    /// correctly — a security record has no business driving a view's
    /// lifecycle. So the detail pane tells the parent and both halves
    /// re-read. Without it the sidebar keeps saying "Refused" until the
    /// window is reopened, which is the same class of bug as a setting read
    /// once when a view was built.
    @State private var defaultsRevision = 0

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.rows) { row in
                                        languageRow(row)
                                            .id(row.id)
                                    }
                                } header: {
                                    sectionHeader(
                                        title: section.category.title,
                                        systemImage: section.category.systemImage,
                                        count: section.rows.count
                                    )
                                }
                            }

                            if sections.isEmpty {
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
                    .onAppear { landOnRequestedRow(proxy) }
                    .onChange(of: navigation.target) { _ in landOnRequestedRow(proxy) }
                }
            }
            .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)

            Divider()

            Group {
                if let selection, let row = allRows.first(where: { $0.id == selection }) {
                    detail(for: row)
                        .id(selection)
                } else {
                    /// Nothing picked yet — or the catalog reloaded and took
                    /// the selected row with it, an extension removed from the
                    /// directory while this screen was open.
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Languages")
        // Opening this screen is the moment the answer matters, and it is
        // also the moment after which the user most often installs something
        // in the terminal next to it.
        .task {
            lsp.refreshInstalledCommands()
            /// One `npm root -g` for the whole screen, here rather than in a
            /// popover's `body`. See `LSPDependencyCenter`.
            LSPDependencyCenter.shared.refresh()
        }
    }

    /// Answers a request to open this screen at one server — the editor's
    /// banner about a server that failed is the caller that has one.
    ///
    /// The search field is cleared first: a query left over from the last
    /// visit filters the list, and a row that is filtered out cannot be
    /// selected or scrolled to. The request is consumed here, so opening
    /// Settings from the menu afterwards lands where the reader left it.
    private func landOnRequestedRow(_ proxy: ScrollViewProxy) {
        guard let target = navigation.target, target.section == .languageServers else { return }
        navigation.target = nil
        guard let row = target.row else { return }

        searchText = ""
        selection = row

        /// Next turn of the loop, not this one: the list is lazy, so the
        /// row being asked for may not exist until the selection above has
        /// been drawn.
        DispatchQueue.main.async {
            proxy.scrollTo(row, anchor: .center)
        }
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

    /// The rows, grouped by category, both levels sorted by name and empty
    /// sections dropped.
    ///
    /// Alphabetical rather than curated, because the list is long enough to
    /// scroll and any other order is one only its author knows. The two
    /// TypeScript servers landing apart — one near the top, one seven rows
    /// below it — is what a declared order produces once a table outgrows
    /// the reasoning that arranged it.
    ///
    /// `localizedStandardCompare` rather than `<`: it folds case and reads
    /// digits as numbers, so "TypeScript 7 (Go)" sorts next to
    /// "TypeScript (npm)" instead of by the ASCII value of a bracket.
    private var sections: [LanguageServerSection] {
        var byCategory: [LSPServerCategory: [LanguageRow]] = [:]
        for row in filteredRows {
            byCategory[row.category, default: []].append(row)
        }
        return LSPServerCategory.allCases
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .compactMap { category in
                guard let rows = byCategory[category], !rows.isEmpty else { return nil }
                return LanguageServerSection(
                    category: category,
                    rows: rows.sorted {
                        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    })
            }
    }

    private func languageRow(_ row: LanguageRow) -> some View {
        let isSelected = selection == row.id

        return Button {
            selection = row.id
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

/// One selectable language, from either table.
private enum LanguageRow: Identifiable {
    case server(LSPServerDefinition)
    case contributed(LanguageCatalog.Contributed)

    /// Prefixed by kind, because a contributed language is free to name
    /// itself after a binary and nothing stops the two ids colliding.
    ///
    /// Spelled by ``SettingsNavigation`` rather than here, because a caller
    /// that wants this screen opened at one row has to name the same string.
    var id: String {
        switch self {
        case .server(let server): return SettingsNavigation.serverRow(server.command)
        case .contributed(let contributed): return SettingsNavigation.contributedRow(contributed.id)
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
    @ObservedObject private var dependencies = LSPDependencyCenter.shared
    @State private var operation: ServerInstallOperation = .none
    @State private var operationError: String?
    @State private var operationOutput: [String] = []
    @State private var showUninstallConfirmation = false
    @State private var showDependencies = false

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
            } else if let plan = server.dependencyPlan {
                /// A server whose binary is present can still be unusable
                /// because a package beside it is missing, and that is the
                /// case this whole popover exists for: `vue-language-server`
                /// on `PATH` used to mean "Uninstall" and nothing else, with
                /// `@vue/typescript-plugin` unreachable from any screen.
                HStack(spacing: 8) {
                    dependencyButton(plan)
                    if isInstalled { uninstallButton }
                }
            } else if isInstalled {
                uninstallButton
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

    private var uninstallButton: some View {
        Button(role: .destructive) {
            showUninstallConfirmation = true
        } label: {
            Label("Uninstall", systemImage: "trash")
        }
        .disabled(server.uninstallCommand == nil)
        .help(server.uninstallCommand == nil
            ? "No automatic uninstall for this server."
            : "Removes the server and its packages")
    }

    /// Opens the per-package popover, labelled with what is actually wrong.
    ///
    /// "Install" while nothing is there, a count once some of it is — because
    /// a button that says "Install" beside an installed server reads as a
    /// mistake, and the reader stops trusting the row.
    private func dependencyButton(_ plan: LSPServerDependencyPlan) -> some View {
        let statuses = dependencies.statuses(
            for: plan,
            installedCommands: lsp.installedCommands,
            commandsProbed: lsp.hasProbedInstalls
        )
        let outstanding = plan.packages.filter { (statuses[$0.id] ?? .unknown).needsInstall }

        let title: String
        let symbol: String
        if outstanding.isEmpty {
            title = "Dependencies"
            symbol = "checklist"
        } else if outstanding.count == plan.packages.count {
            title = "Install"
            symbol = "arrow.down.circle"
        } else {
            /// `verbatim`, because interpolating a number through
            /// `LocalizedStringKey` formats it for the locale.
            title = "Install \(outstanding.count) of \(plan.packages.count)"
            symbol = "arrow.down.circle"
        }

        return Button {
            showDependencies = true
        } label: {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: symbol)
            }
        }
        .help("This server needs more than one package — choose which to install")
        .popover(isPresented: $showDependencies, arrowEdge: .bottom) {
            ServerDependencyPopover(server: server, plan: plan) { command in
                showDependencies = false
                run(.installing, command: command)
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
            /// The whole plan, pinned, for a server that has one — otherwise
            /// this row and the Copy button beside it would keep handing out
            /// the unpinned one-package `installHint` while the button above
            /// runs something else entirely.
            if let plan = server.dependencyPlan,
               let planned = server.installCommand(
                   forDependencies: Set(plan.packages.map(\.id))
               ) {
                return planned
            }
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
        run(operation, command: command)
    }

    /// The same run, for a command already resolved by the caller.
    ///
    /// Split out for the dependency popover, which composes its command from
    /// the boxes that are ticked. **Every string that reaches here is still
    /// built from compiled-in literals** — the popover's is assembled by
    /// `LSPServerDefinition.installCommand(forDependencies:)`, which refuses
    /// any definition that is not `.builtIn` and keeps only members of that
    /// server's own plan.
    private func run(_ operation: ServerInstallOperation, command: String) {
        guard operation != .none else { return }

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
                /// The binaries are re-probed by the line above; the packages
                /// that ship no binary are only visible to this one.
                LSPDependencyCenter.shared.refresh()
            } else {
                operationError = result.message
            }
        }
    }
}

/// The per-package install sheet: a checkbox per dependency, ticked for what
/// this machine is missing, and one sentence each saying when it is needed.
///
/// **It explains the rule and does not pretend to answer a case.** Settings is
/// a global screen with no workspace in context, so "your project needs this"
/// is a sentence it is not entitled to say. The project-specific answer
/// already exists in the editor's own server banner, which does know the
/// workspace root — `plan.projectNote` is where this view hands the question
/// over rather than duplicating it badly.
private struct ServerDependencyPopover: View {
    let server: LSPServerDefinition
    let plan: LSPServerDependencyPlan
    let onInstall: (String) -> Void

    @ObservedObject private var lsp = LSPCenter.shared
    @ObservedObject private var dependencies = LSPDependencyCenter.shared

    @State private var selected: Set<String> = []

    /// Seeded once, and only once both probes have answered.
    ///
    /// The popover can open before `npm root -g` returns, and re-seeding on
    /// every publish would untick a box the reader just unticked. Seeding
    /// before the answer arrives would tick every line, which is the same
    /// wrong guess as showing "Install" for an installed server.
    @State private var didSeed = false

    private var statuses: [String: LSPDependencyStatus] {
        dependencies.statuses(
            for: plan,
            installedCommands: lsp.installedCommands,
            commandsProbed: lsp.hasProbedInstalls
        )
    }

    /// Nil when nothing is ticked — which is also what disables Install, so
    /// the button and the command shown under it can never disagree.
    private var command: String? {
        server.installCommand(forDependencies: selected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Install \(server.displayName)")
                .font(.headline)

            Text(
                """
                Ticked by default: what this machine is missing, or has at a \
                version Phantom did not pin. Nothing here knows which project \
                you mean — each line says when its package is needed.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.packages) { dependency in
                    dependencyRow(dependency)
                }
            }

            if let note = plan.projectNote {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(.tertiary)
                    Text(verbatim: note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Group {
                if let command {
                    Text(verbatim: command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Nothing selected.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Spacer()
                Button {
                    guard let command else { return }
                    onInstall(command)
                } label: {
                    Text("Install")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(command == nil)
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear(perform: seedIfNeeded)
        .onChange(of: dependencies.hasProbed) { _ in seedIfNeeded() }
        .onChange(of: lsp.hasProbedInstalls) { _ in seedIfNeeded() }
    }

    private func dependencyRow(_ dependency: LSPServerDependency) -> some View {
        let status = statuses[dependency.id] ?? .unknown

        return Toggle(isOn: binding(for: dependency.id)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    /// `verbatim` for both: a package name contains `@` and
                    /// `/`, and a purpose contains `<template>` — the
                    /// interpolating initializer runs its argument through
                    /// `LocalizedStringKey`, markdown and all.
                    Text(verbatim: dependency.spec)
                        .font(.system(size: 12, design: .monospaced))
                    statusChip(status)
                }
                Text(verbatim: dependency.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusChip(_ status: LSPDependencyStatus) -> some View {
        switch status {
        case .unknown:
            Text("Checking…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .missing:
            Text("Missing")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .outdated(let installed):
            /// Named, not just flagged: "this machine has 2.2.12" is what
            /// tells a reader the tick below is about a skew rather than an
            /// absence, and skew is the failure that reports itself as
            /// nothing at all.
            Text(verbatim: "Has \(installed)")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .present:
            Text("Installed")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn {
                    selected.insert(id)
                } else {
                    selected.remove(id)
                }
            }
        )
    }

    private func seedIfNeeded() {
        guard !didSeed, dependencies.hasProbed, lsp.hasProbedInstalls else { return }
        didSeed = true
        selected = LSPDependencyCatalog.defaultSelection(for: plan, statuses: statuses)
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

    /// Stops this server under every command it could be running as — the
    /// default, and whatever the reader has typed over it — and re-announces
    /// the open files to whatever starts next.
    private func restart() {
        let outcome = LSPRestart.restart(commands: [defaultCommand, override.command])
        restartNote = outcome.stopped == 0
            ? "Nothing was running; it will start clean."
            : "Stopped \(outcome.stopped) workspace\(outcome.stopped == 1 ? "" : "s")."
    }

    /// What the last restart did, so the button says something happened.
    ///
    /// A button that changes nothing visible reads as a broken button, and
    /// this one's whole effect is somewhere else — a server that is quietly
    /// running with different options now.
    @State private var restartNote: String?

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
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        """
                        Blank uses the default above. Takes effect the next \
                        time this server starts for a workspace.
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    /// Here rather than only in the sentence above, because
                    /// the reader who just changed a field is the reader who
                    /// needs it applied, and the instruction they used to get
                    /// was to relaunch the app.
                    HStack(spacing: 8) {
                        Button("Restart Server") { restart() }
                        if let note = restartNote {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
    /// The asset name of the logo for this row, or nil when the app ships no
    /// logo for it.
    ///
    /// **The command is asked first**, because a few servers are identified by
    /// the tool rather than by the language. Tailwind's row is registered under
    /// five language ids it does not own — it is the *second* server for each —
    /// so resolving by language id alone drew it with the HTML logo, which is
    /// the logo of the server sitting above it in the same list.
    var languageIconName: String? {
        if let byCommand = Self.iconName(forCommand: command) { return byCommand }
        return Self.iconName(forLanguageID: languageID)
    }

    /// A logo that belongs to the binary, not to a language.
    ///
    /// Deliberately not a general fallthrough: every other server in this
    /// registry *is* its language's server, and giving those a command-keyed
    /// logo would mean two tables claiming the same row.
    static func iconName(forCommand command: String) -> String? {
        switch command {
        case LSPServerRegistry.tailwindCommand: return "Lang-tailwind"
        default: return nil
        }
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
        case "toml": base = "toml"
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
