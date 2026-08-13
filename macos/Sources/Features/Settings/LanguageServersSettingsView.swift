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
            Text("\(section.servers.count)")
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
private struct LanguageServerOverrideForm: View {
    let server: LSPServerDefinition
    @State private var override: LSPServerOverride
    @State private var installing = false
    @State private var installError: String?

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
                if let url = server.documentationURL {
                    Link(destination: url) {
                        Label("Documentation", systemImage: "book.closed")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Form {
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        LSPStatusBadge(status: LSPCenter.shared.status(for: server), detailed: true)
                    }
                }

                Section {
                    CopyableValueRow(title: "Default Command", value: server.invocation)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Install")
                                .font(.headline)
                            Text(server.installCommand)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let helper = server.installHelper {
                                Text(helper)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            if let installError {
                                Text(installError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer(minLength: 8)
                        Button {
                            runInstall()
                        } label: {
                            if installing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Install", systemImage: "arrow.down.circle")
                            }
                        }
                        .disabled(installing)
                        .help("Runs the install command above in a terminal with your login environment")
                        CopyButton(text: server.installCommand, label: "Copy")
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: override) { value in
            LSPServerOverrideStore.set(value, for: server.command)
        }
    }

    /// Runs the install command through the user's login shell so `npm`,
    /// `go`, `brew`, `gem` — whichever the hint uses — are on `PATH`. Runs
    /// off the main actor; the result lands back on it.
    private func runInstall() {
        installing = true
        installError = nil

        let command = server.installCommand
        Task { [self] in
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let environment = await Task.detached(priority: .userInitiated) {
                LoginEnvironment.executableEnvironment()
            }.value
            let result = await Task.detached(priority: .userInitiated) {
                ShellCommand.runResult(
                    shell,
                    ["-lic", command],
                    environment: environment,
                    timeout: 300
                )
            }.value

            installing = false
            if result.succeeded {
                LSPCenter.shared.recheckMissingServers()
            } else {
                installError = result.message
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
                Text("· \\(status.activeWorkspaceCount) workspace\\(status.activeWorkspaceCount == 1 ? \"\" : \"s\")")
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
