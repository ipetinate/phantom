import SwiftUI

struct ExtensionsSettingsView: View {
    @ObservedObject private var store = ExtensionStore.shared
    @ObservedObject private var navigation = SettingsNavigation.shared

    @State private var searchText = ""
    @State private var hasRequestedRegistry = false

    var body: some View {
        Form {
            Section { headerRow }
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
}
