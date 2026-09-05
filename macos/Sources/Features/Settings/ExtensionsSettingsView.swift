import SwiftUI

struct ExtensionsSettingsView: View {
    @ObservedObject private var store = ExtensionStore.shared
    @ObservedObject private var navigation = SettingsNavigation.shared

    @State private var searchText = ""
    @State private var hasRequestedRegistry = false

    var body: some View {
        Form {
            Section {
                headerRow
                if store.index != nil, let error = store.lastRefreshError {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            registryContent
        }
        .formStyle(.grouped)
        .navigationTitle("Extensions")
        .onAppear {
            consumeRequest()
            loadOnce()
        }
        .onChange(of: navigation.target) { _ in consumeRequest() }
    }

    private func consumeRequest() {
        guard navigation.target?.section == .extensions else { return }
        navigation.target = nil
    }

    private func loadOnce() {
        guard !hasRequestedRegistry else { return }
        hasRequestedRegistry = true
        store.reloadInstalled()
        Task { await store.refresh() }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText, prompt: Text("Search extensions"))
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Refresh") {
                Task { await store.refresh() }
            }
            .disabled(store.isRefreshing)
        }
    }

    // MARK: Registry

    @ViewBuilder
    private var registryContent: some View {
        if let index = store.index {
            listSections(index)
        } else if !store.isRefreshing, let error = store.lastRefreshError {
            Section {
                LabeledContent {
                    Button("Retry") {
                        Task { await store.refresh() }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The registry could not be loaded.")
                        Text(verbatim: error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        } else {
            Section {
                HStack {
                    Spacer()
                    ProgressView("Loading the registry…")
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func listSections(_ index: ExtensionIndex) -> some View {
        let entries = visibleEntries(index)
        let orphans = visibleOrphans(index)

        if index.extensions.isEmpty {
            Section { message("The registry has no extensions yet.") }
        } else if entries.isEmpty, orphans.isEmpty {
            Section { message("No extension matches.") }
        } else if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    entryRow(entry)
                }
            } header: {
                Text("Registry")
            } footer: {
                Text("Each extension is a zip published as a GitHub release of the registry. Phantom checks its digest against the index before unpacking it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if !orphans.isEmpty {
            Section {
                ForEach(orphans) { installed in
                    orphanRow(installed)
                }
            } header: {
                Text("Installed, not in the registry")
            } footer: {
                Text("Found in the extensions folder, but the registry no longer lists them — or never did, if they were copied in by hand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
    }

    private func visibleEntries(_ index: ExtensionIndex) -> [ExtensionIndex.Entry] {
        let query = needle
        return index.extensions
            .filter { entry in
                query.isEmpty || ([entry.name, entry.id, entry.publisher, entry.summary] + entry.languages)
                    .contains { $0.lowercased().contains(query) }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func visibleOrphans(_ index: ExtensionIndex) -> [InstalledExtension] {
        let query = needle
        let listed = Set(index.extensions.map(\.id))
        return store.installed
            .filter { !listed.contains($0.id) }
            .filter { installed in
                query.isEmpty || [installed.name, installed.id].contains { $0.lowercased().contains(query) }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var needle: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Rows

    private func entryRow(_ entry: ExtensionIndex.Entry) -> some View {
        let state = store.state(for: entry)

        return LabeledContent {
            HStack(spacing: 10) {
                stateBadge(state)
                if let activity = store.activity[entry.id] {
                    activityView(activity)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: entry.name)
                    Text(verbatim: versionText(entry, state: state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: entry.publisher)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !entry.summary.isEmpty {
                    Text(verbatim: entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !entry.contributes.isEmpty {
                    chips(for: entry)
                }
                if let error = store.errors[entry.id] {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .help(entry.id)
        }
    }

    private func orphanRow(_ installed: InstalledExtension) -> some View {
        LabeledContent {
            if let activity = store.activity[installed.id] {
                activityView(activity)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: installed.name)
                    Text(verbatim: installed.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: installed.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = store.errors[installed.id] {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func versionText(_ entry: ExtensionIndex.Entry, state: ExtensionState) -> String {
        if case .updateAvailable(let installed, let available) = state {
            return "\(installed) \u{2192} \(available)"
        }
        return entry.version
    }

    @ViewBuilder
    private func stateBadge(_ state: ExtensionState) -> some View {
        switch state {
        case .notInstalled:
            EmptyView()
        case .installed:
            badge("Installed", color: .green)
        case .updateAvailable:
            badge("Update available", color: .orange)
        }
    }

    private func badge(_ title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func activityView(_ activity: ExtensionActivity) -> some View {
        HStack(spacing: 8) {
            if case .downloading(let fraction?) = activity {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 100)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(activityLabel(activity))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func activityLabel(_ activity: ExtensionActivity) -> LocalizedStringKey {
        switch activity {
        case .downloading: return "Downloading…"
        case .verifying: return "Verifying…"
        case .installing: return "Installing…"
        case .removing: return "Removing…"
        }
    }

    // MARK: Chips

    private func chips(for entry: ExtensionIndex.Entry) -> some View {
        HStack(spacing: 4) {
            ForEach(entry.contributes, id: \.self) { kind in
                chip(ExtensionContributionChip.of(kind))
                    .help(kind == "languages" && !entry.languages.isEmpty
                        ? entry.languages.joined(separator: ", ")
                        : ExtensionContributionChip.of(kind).title)
            }
        }
    }

    private func chip(_ chip: ExtensionContributionChip) -> some View {
        Label(chip.title, systemImage: chip.systemImage)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(Color.secondary.opacity(0.15))
            )
            .foregroundStyle(.secondary)
    }
}

struct ExtensionContributionChip: Equatable {
    let title: String
    let systemImage: String

    static func of(_ kind: String) -> ExtensionContributionChip {
        switch kind {
        case "languages":
            return ExtensionContributionChip(
                title: "Languages", systemImage: "chevron.left.forwardslash.chevron.right")
        case "formatters":
            return ExtensionContributionChip(title: "Formatters", systemImage: "text.alignleft")
        case "themes":
            return ExtensionContributionChip(title: "Themes", systemImage: "paintpalette")
        case "iconThemes":
            return ExtensionContributionChip(title: "Icon Themes", systemImage: "photo.on.rectangle")
        default:
            return ExtensionContributionChip(title: kind, systemImage: "puzzlepiece")
        }
    }
}
