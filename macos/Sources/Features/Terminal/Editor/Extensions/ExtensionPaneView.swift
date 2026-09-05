import AppKit
import SwiftUI

struct ExtensionPaneView: View {
    let document: ExtensionDocument
    let theme: CodeTheme

    @ObservedObject private var store: ExtensionStore = .shared
    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var config: GuiConfigStore = .shared
    @State private var status: ExtensionDocumentView.Status = .rendering

    private var id: String { document.extensionID }

    private var entry: ExtensionIndex.Entry? {
        store.index?.extensions.first { $0.id == id }
    }

    private var installed: InstalledExtension? {
        store.installed.first { $0.id == id }
    }

    private var card: ExtensionCard? { entry?.card }

    private var previewKey: String {
        [id, entry?.version ?? "", installed?.version ?? "", store.index == nil ? "no-index" : "index"]
            .joined(separator: "|")
    }

    var body: some View {
        ZStack {
            Color(nsColor: theme.background)

            if entry == nil && installed == nil {
                if store.isRefreshing || store.index == nil {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    MediaUnreadableView(message: "This extension is no longer in the registry or on disk.")
                }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    documentArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: previewKey) { await requestPreview() }
        .onChange(of: document.id) { _ in status = .rendering }
    }

    private func requestPreview() async {
        if store.index == nil { await store.refresh() }
        if let entry, entry.card != nil {
            await store.preview(entry)
        } else if let installed {
            await store.preview(installed: installed)
        }
    }

    // MARK: Header

    private var title: String { card?.title ?? entry?.name ?? installed?.name ?? document.title }

    private var tagline: String {
        if let tagline = card?.tagline, !tagline.isEmpty { return tagline }
        return entry?.summary ?? ""
    }

    private var versionText: String {
        if let entry { return ExtensionRow.versionText(entry, state: store.state(for: entry)) }
        return installed?.version ?? ""
    }

    private var authorName: String {
        card?.author.name ?? entry?.publisher ?? installed?.publisher ?? ""
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ExtensionIconView(url: iconURL, size: 64)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    if !versionText.isEmpty {
                        ExtensionTagView(text: versionText)
                    }
                    if let entry {
                        ExtensionStateBadge(state: store.state(for: entry))
                    } else if installed != nil {
                        ExtensionStateBadge(state: .installed(version: installed?.version ?? ""))
                    }
                }

                if !tagline.isEmpty {
                    Text(verbatim: tagline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                metadata

                if let card, !card.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(card.tags, id: \.self) { tag in
                            ExtensionTagView(text: tag)
                        }
                    }
                }

                if let entry, !entry.contributes.isEmpty {
                    ExtensionContributionChips(entry: entry)
                }

                actions
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .help(id)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if let url = card?.author.url, !authorName.isEmpty {
                Link(destination: url) {
                    Text(verbatim: authorName)
                }
            } else if !authorName.isEmpty {
                Text(verbatim: authorName)
            }
            if let license = card?.license, !license.isEmpty {
                separator
                Text(verbatim: license)
            }
            if let created = card?.created {
                separator
                Text("Created \(created, format: .dateTime.year().month().day())")
            }
            if let updated = card?.updated {
                separator
                Text("Updated \(updated, format: .dateTime.year().month().day())")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var separator: some View {
        Text(verbatim: "\u{00B7}")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let activity = store.activity[id] {
                    ExtensionActivityView(activity: activity)
                } else if let entry {
                    ExtensionActionButton(
                        state: store.state(for: entry),
                        onInstall: { Task { await store.install(entry) } },
                        onRemove: { Task { await store.remove(id: id) } }
                    )
                } else if installed != nil {
                    Button("Uninstall") {
                        Task { await store.remove(id: id) }
                    }
                }
            }
            if let error = store.errors[id] {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private var iconURL: URL? {
        if let entry { return store.iconURL(for: entry) }
        return installed?.iconURL
    }

    // MARK: Document

    @ViewBuilder
    private var documentArea: some View {
        switch store.previews[id] {
        case .ready(let documentURL, let base)?:
            renderedDocument(documentURL, base: base)
        case .unavailable(let reason)?:
            notice(reason)
        case .loading?:
            ProgressView()
                .controlSize(.small)
        case .none:
            if let entry, entry.card == nil, installed == nil {
                notice(nil)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func renderedDocument(_ documentURL: URL, base: URL) -> some View {
        if let viewer = store.viewerHTML {
            ZStack {
                ExtensionDocumentView(
                    request: ExtensionDocumentView.Request(
                        viewerHTML: viewer,
                        document: documentURL,
                        base: base,
                        cover: card?.cover),
                    theme: ExtensionViewerTheme.current(),
                    onStatus: { status = $0 }
                )
                .opacity(isRendered ? 1 : 0)

                switch status {
                case .rendering:
                    ProgressView()
                        .controlSize(.small)
                case .failed(let message, let line, let column):
                    notice(Self.failureText(message, line: line, column: column))
                case .rendered:
                    EmptyView()
                }
            }
        } else {
            notice(ExtensionViewerBundle.Failure.missing.message)
        }
    }

    private var isRendered: Bool {
        if case .rendered = status { return true }
        return false
    }

    static func failureText(_ message: String, line: Int?, column: Int?) -> String {
        guard let line else { return "The document could not be rendered: \(message)" }
        guard let column else { return "The document could not be rendered at line \(line): \(message)" }
        return "The document could not be rendered at line \(line), column \(column): \(message)"
    }

    private func notice(_ reason: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let reason {
                    Text(verbatim: reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary = entry?.summary, !summary.isEmpty {
                    Text(verbatim: summary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if reason == nil {
                    Text("This extension ships no document.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}
