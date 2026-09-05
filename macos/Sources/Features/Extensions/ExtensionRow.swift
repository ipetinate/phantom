import AppKit
import SwiftUI

struct ExtensionRow: View {
    enum Style {
        case form
        case compact
    }

    enum Subject {
        case entry(ExtensionIndex.Entry, state: ExtensionState)
        case orphan(InstalledExtension)

        var id: String {
            switch self {
            case .entry(let entry, _): return entry.id
            case .orphan(let installed): return installed.id
            }
        }

        var name: String {
            switch self {
            case .entry(let entry, _): return entry.name
            case .orphan(let installed): return installed.name
            }
        }

        var versionText: String {
            switch self {
            case .entry(let entry, let state): return ExtensionRow.versionText(entry, state: state)
            case .orphan(let installed): return installed.version
            }
        }

        var state: ExtensionState? {
            if case .entry(_, let state) = self { return state }
            return nil
        }
    }

    let subject: Subject
    let style: Style
    let activity: ExtensionActivity?
    let error: String?
    let onInstall: () -> Void
    let onRemove: () -> Void

    var body: some View {
        switch style {
        case .form:
            formBody
        case .compact:
            compactBody
        }
    }

    static func versionText(_ entry: ExtensionIndex.Entry, state: ExtensionState) -> String {
        if case .updateAvailable(let installed, let available) = state {
            return "\(installed) \u{2192} \(available)"
        }
        return entry.version
    }

    // MARK: Form

    @ViewBuilder
    private var formBody: some View {
        switch subject {
        case .entry(let entry, let state):
            LabeledContent {
                HStack(spacing: 10) {
                    ExtensionStateBadge(state: state)
                    trailing
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    titleLine
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
                        ExtensionContributionChips(entry: entry)
                    }
                    errorLine
                }
                .help(entry.id)
            }

        case .orphan(let installed):
            LabeledContent {
                trailing
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    titleLine
                    Text(verbatim: installed.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    errorLine
                }
            }
        }
    }

    // MARK: Compact

    private var compactBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            titleLine
            if let state = subject.state {
                ExtensionStateBadge(state: state)
            }
            Spacer(minLength: 8)
            trailing
        }
        .help(subject.id)
    }

    // MARK: Shared

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: subject.name)
                .lineLimit(1)
            Text(verbatim: subject.versionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error {
            Text(verbatim: error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let activity {
            ExtensionActivityView(activity: activity)
        } else {
            ExtensionActionButton(state: subject.state ?? .installed(version: ""), onInstall: onInstall, onRemove: onRemove)
        }
    }
}

struct ExtensionActionButton: View {
    let state: ExtensionState
    let onInstall: () -> Void
    let onRemove: () -> Void

    var body: some View {
        switch state {
        case .notInstalled:
            Button("Install", action: onInstall)
        case .installed:
            Button("Remove", action: onRemove)
        case .updateAvailable:
            Button("Update", action: onInstall)
        }
    }
}

struct ExtensionStateBadge: View {
    let state: ExtensionState

    var body: some View {
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
}

struct ExtensionActivityView: View {
    let activity: ExtensionActivity

    var body: some View {
        HStack(spacing: 8) {
            if case .downloading(let fraction?) = activity {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 100)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var label: LocalizedStringKey {
        switch activity {
        case .downloading: return "Downloading…"
        case .verifying: return "Verifying…"
        case .installing: return "Installing…"
        case .removing: return "Removing…"
        }
    }
}

struct ExtensionContributionChips: View {
    let entry: ExtensionIndex.Entry

    var body: some View {
        HStack(spacing: 4) {
            ForEach(entry.contributes, id: \.self) { kind in
                ExtensionChipView(chip: ExtensionContributionChip.of(kind))
                    .help(kind == "languages" && !entry.languages.isEmpty
                        ? entry.languages.joined(separator: ", ")
                        : ExtensionContributionChip.of(kind).title)
            }
        }
    }
}

struct ExtensionTagView: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(Color.secondary.opacity(0.15))
            )
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct ExtensionIconView: View {
    let url: URL?
    var size: CGFloat = 28

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(
                        Image(systemName: ExtensionDocument.symbol)
                            .font(.system(size: size * 0.45, weight: .semibold))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            image = await Self.load(url)
        }
    }

    static func load(_ url: URL?) async -> NSImage? {
        guard let url else { return nil }
        let data = await Task.detached(priority: .utility) { () -> Data? in
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size <= ExtensionMediaGate.maxImageBytes
            else { return nil }
            return try? Data(contentsOf: url)
        }.value
        guard let data, let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        return image
    }
}

struct ExtensionChipView: View {
    let chip: ExtensionContributionChip

    var body: some View {
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
