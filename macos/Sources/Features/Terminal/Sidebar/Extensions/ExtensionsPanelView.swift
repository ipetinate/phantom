import SwiftUI

struct ExtensionsPanelView: View {
    @ObservedObject private var store: ExtensionStore = .shared
    @ObservedObject private var palette: ThemePalette = .shared

    @State private var searchText = ""
    @State private var selectedID: String?
    @State private var hasLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            search
            registryContent
        }
        .onAppear(perform: loadOnce)
    }

    private func loadOnce() {
        guard !hasLoaded else { return }
        hasLoaded = true
        store.reloadInstalled()
        Task { await store.refresh() }
    }

    private var search: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            TextField("Search extensions", text: $searchText)
                .textFieldStyle(.plain)
                .font(palette.font(size: 11))

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else if !searchText.isEmpty {
                Button {
                    searchText = ""
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

    @ViewBuilder
    private var registryContent: some View {
        if let index = store.index {
            if let error = store.lastRefreshError {
                Text(verbatim: error)
                    .font(palette.font(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            list(index)
        } else if !store.isRefreshing, let error = store.lastRefreshError {
            failure(error)
        } else {
            ProgressView("Loading the registry…")
                .controlSize(.small)
                .font(palette.font(size: 11))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func failure(_ error: String) -> some View {
        VStack(spacing: 8) {
            Text("The registry could not be loaded.")
                .font(palette.font(size: 11))
            Text(verbatim: error)
                .font(palette.font(size: 10))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") {
                Task { await store.refresh() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ index: ExtensionIndex) -> some View {
        let sections = ExtensionListFilter.sections(
            entries: index.extensions, installed: store.installed, query: searchText)

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if index.extensions.isEmpty {
                    message("The registry has no extensions yet.")
                } else if sections.isEmpty {
                    message("No extension matches.")
                } else {
                    ForEach(sections.entries) { entry in
                        row(for: entry)
                    }
                }

                if !sections.orphans.isEmpty {
                    Text("Installed, not in the registry")
                        .font(palette.font(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                    ForEach(sections.orphans) { installed in
                        row(for: installed)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func row(for entry: ExtensionIndex.Entry) -> some View {
        ExtensionRow(
            subject: .entry(entry, state: store.state(for: entry)),
            style: .compact,
            iconURL: store.iconURL(for: entry),
            activity: store.activity[entry.id],
            error: store.errors[entry.id],
            isSelected: selectedID == entry.id,
            onOpen: {
                selectedID = entry.id
                ExtensionDocumentTabs.open(entry)
            },
            onInstall: { Task { await store.install(entry) } },
            onRemove: { Task { await store.remove(id: entry.id) } }
        )
        .contextMenu { openInSettings(id: entry.id) }
    }

    private func row(for installed: InstalledExtension) -> some View {
        ExtensionRow(
            subject: .orphan(installed),
            style: .compact,
            iconURL: installed.iconURL,
            activity: store.activity[installed.id],
            error: store.errors[installed.id],
            isSelected: selectedID == installed.id,
            onOpen: {
                selectedID = installed.id
                ExtensionDocumentTabs.open(installed: installed)
            },
            onInstall: {},
            onRemove: { Task { await store.remove(id: installed.id) } }
        )
        .contextMenu { openInSettings(id: installed.id) }
    }

    private func openInSettings(id: String) -> some View {
        Button("Open in Settings") {
            ExtensionDocumentTabs.openInSettings(id: id)
        }
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(palette.font(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}
