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
/// Live per-file server status already lives in the editor's own banner,
/// scoped to the workspace that's actually open — a language can be
/// running in one window's root and crashed in another's, so a global
/// status row here would just be misleading. This view is only the
/// configuration half.
struct LanguageServersSettingsView: View {
    @State private var selection: LSPServerDefinition?
    @State private var searchText = ""
    @ObservedObject private var lsp = LSPCenter.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.servers) { server in
                                    row(for: server)
                                }
                            } header: {
                                sectionHeader(section)
                            }
                        }

                        if filteredServers.isEmpty {
                            Text("No language servers match “\(searchText)”.")
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
                if let selection {
                    LanguageServerOverrideForm(server: selection)
                        .id(selection.id)
                } else {
                    Text("Select a language server.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// A server matches the query when any of the words a user would type
    /// to find it — its name, binary, language id, or file extensions —
    /// contains the query. Matching is case-insensitive.
    private var filteredServers: [LSPServerDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return LSPServerRegistry.distinctServers }
        let needle = query.lowercased()
        return LSPServerRegistry.distinctServers.filter { server in
            let haystack = [
                server.displayName,
                server.command,
                server.languageID,
                fileExtensions(sharing: server.command),
            ].joined(separator: " ").lowercased()
            return haystack.contains(needle)
        }
    }

    /// The distinct servers, grouped by category, with sections in the
    /// category's declared order and empty sections dropped.
    private var sections: [LanguageServerSection] {
        var byCategory: [LSPServerCategory: [LSPServerDefinition]] = [:]
        for server in filteredServers {
            byCategory[server.category, default: []].append(server)
        }
        return LSPServerCategory.allCases.compactMap { category in
            guard let servers = byCategory[category], !servers.isEmpty else { return nil }
            return LanguageServerSection(category: category, servers: servers)
        }
    }

    private func row(for server: LSPServerDefinition) -> some View {
        Button {
            selection = server
        } label: {
            HStack(alignment: .center, spacing: 8) {
                LanguageIconView(name: server.languageIconName)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(server.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        LSPStatusIcon(status: lsp.status(for: server))
                    }
                    Text(fileExtensions(sharing: server.command))
                        .font(.caption)
                        .foregroundStyle(selection == server ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(selection == server ? Color.accentColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText, prompt: Text("Search language servers"))
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

    private func sectionHeader(_ section: LanguageServerSection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: section.category.systemImage)
            Text(section.category.title)
            Spacer()
            Text(verbatim: "\(section.servers.count)")
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

    private func fileExtensions(sharing command: String) -> String {
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

/// A category heading plus its servers, in display order.
private struct LanguageServerSection: Identifiable {
    let category: LSPServerCategory
    let servers: [LSPServerDefinition]

    var id: LSPServerCategory { category }
}

/// One server's editable override, backed by `LSPServerOverrideStore`.
///
/// Split out from the list above so `.id(selection.id)` there forces a
/// fresh `@State` per server — without it, switching the sidebar selection
/// would keep editing the previous server's override in place, since
/// SwiftUI would otherwise reuse the same view identity and its state.
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
    @State private var override: LSPServerOverride
    @State private var operation: ServerInstallOperation = .none
    @State private var operationError: String?
    @State private var operationOutput: [String] = []
    @State private var showUninstallConfirmation = false

    init(server: LSPServerDefinition) {
        self.server = server
        _override = State(initialValue: LSPServerOverrideStore.override(for: server.command) ?? LSPServerOverride())
    }

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

                Section {
                    TextField("Command", text: $override.command, prompt: Text(server.command))
                    TextField(
                        "Arguments",
                        text: $override.arguments,
                        prompt: Text(server.arguments.joined(separator: " "))
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
        .onChange(of: override) { value in
            LSPServerOverrideStore.set(value, for: server.command)
        }
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
            return server.installCommand
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

private extension LSPServerDefinition {
    /// The asset name of the language's logo, or nil when the app ships no
    /// logo for this server's language.
    var languageIconName: String? {
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
private struct LanguageIconView: View {
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

private struct CopyableValueRow: View {
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
