import AppKit
import SwiftUI

enum ExtensionsPanelSubject: Equatable {
    case listed(ExtensionIndex.Entry)
    case orphan(InstalledExtension)

    var id: String {
        switch self {
        case .listed(let entry): return entry.id
        case .orphan(let installed): return installed.id
        }
    }

    var name: String {
        switch self {
        case .listed(let entry): return entry.name
        case .orphan(let installed): return installed.name
        }
    }

    var byline: String {
        switch self {
        case .listed(let entry): return entry.publisher
        case .orphan(let installed): return installed.id
        }
    }

    var entry: ExtensionIndex.Entry? {
        if case .listed(let entry) = self { return entry }
        return nil
    }
}

struct ExtensionsPanelDetail: View {
    let subject: ExtensionsPanelSubject
    @ObservedObject var store: ExtensionStore
    let onBack: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared

    private var state: ExtensionState {
        switch subject {
        case .listed(let entry): return store.state(for: entry)
        case .orphan(let installed): return .installed(version: installed.version)
        }
    }

    private var version: String {
        switch subject {
        case .listed(let entry): return ExtensionsPanelText.version(entry.version, state: state)
        case .orphan(let installed): return installed.version
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    identity
                    ExtensionsPanelStateBadge(state: state)
                    if let summary = subject.entry?.summary, !summary.isEmpty {
                        Text(verbatim: summary)
                            .font(palette.font(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let entry = subject.entry, !entry.contributes.isEmpty {
                        chips(for: entry)
                    }
                    actionRow
                    if let error = store.errors[subject.id] {
                        Text(verbatim: error)
                            .font(palette.font(size: 10))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    Button("Open in Settings", action: openInSettings)
                        .font(palette.font(size: 11))
                        .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            SidebarIconButton(help: "Back", action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: subject.name)
                .font(palette.font(size: 11, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: subject.name)
                    .font(palette.font(size: 13, weight: .semibold))
                Text(verbatim: version)
                    .font(palette.font(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: subject.byline)
                .font(palette.font(size: 10))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .help(subject.id)
    }

    @ViewBuilder
    private var actionRow: some View {
        if let activity = store.activity[subject.id] {
            HStack(spacing: 6) {
                if case .downloading(let fraction?) = activity {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(ExtensionsPanelText.activityLabel(activity))
                    .font(palette.font(size: 10))
                    .foregroundStyle(.secondary)
            }
        } else {
            actionButton
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch subject {
        case .listed(let entry):
            switch state {
            case .notInstalled:
                Button("Install") {
                    Task { await store.install(entry) }
                }
            case .installed:
                Button("Remove") {
                    Task { await store.remove(id: entry.id) }
                }
            case .updateAvailable:
                Button("Update") {
                    Task { await store.install(entry) }
                }
            }
        case .orphan(let installed):
            Button("Remove") {
                Task { await store.remove(id: installed.id) }
            }
        }
    }

    private func chips(for entry: ExtensionIndex.Entry) -> some View {
        ExtensionsPanelChips(kinds: entry.contributes, languages: entry.languages)
    }

    private func openInSettings() {
        SettingsNavigation.shared.target = SettingsNavigation.Target(
            section: .extensions,
            row: SettingsNavigation.contributedRow(subject.id)
        )
        _ = NSApp.sendAction(#selector(AppDelegate.openConfig(_:)), to: nil, from: nil)
    }
}

private struct ExtensionsPanelChips: View {
    let kinds: [String]
    let languages: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(kinds, id: \.self) { kind in
                chip(ExtensionContributionChip.of(kind))
                    .help(kind == "languages" && !languages.isEmpty
                        ? languages.joined(separator: ", ")
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
