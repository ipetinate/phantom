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

        var title: String {
            switch self {
            case .entry(let entry, _): return entry.card?.title ?? entry.name
            case .orphan(let installed): return installed.name
            }
        }

        var author: String {
            switch self {
            case .entry(let entry, _): return entry.card?.author.name ?? entry.publisher
            case .orphan(let installed): return installed.publisher.isEmpty ? installed.id : installed.publisher
            }
        }

        var versionText: String {
            switch self {
            case .entry(let entry, let state): return ExtensionRow.versionText(entry, state: state)
            case .orphan(let installed): return installed.version
            }
        }

        var state: ExtensionState {
            switch self {
            case .entry(_, let state): return state
            case .orphan(let installed): return .installed(version: installed.version)
            }
        }
    }

    let subject: Subject
    let style: Style
    let iconURL: URL?
    let activity: ExtensionActivity?
    let error: String?
    var isSelected = false
    let onOpen: () -> Void
    let onInstall: () -> Void
    let onRemove: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @State private var isHovered = false

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

    private var formBody: some View {
        LabeledContent {
            trailing(controlSize: .regular)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                ExtensionIconView(url: iconURL, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: subject.title)
                            .lineLimit(1)
                        ExtensionTagView(text: subject.versionText)
                    }
                    Text(verbatim: subject.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let error {
                        Text(verbatim: error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .help(subject.id)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    // MARK: Compact

    private var compactBody: some View {
        HStack(spacing: 8) {
            ExtensionIconView(url: iconURL, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: subject.title)
                        .font(palette.font(size: 11, weight: .medium))
                        .lineLimit(1)
                    ExtensionTagView(text: subject.versionText)
                }
                Text(verbatim: subject.author)
                    .font(palette.font(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            trailing(controlSize: .small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(compactBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .help(error ?? subject.id)
    }

    private var compactBackground: Color {
        if isSelected { return (palette.accent ?? .accentColor).opacity(0.18) }
        return isHovered ? Color.primary.opacity(0.06) : .clear
    }

    // MARK: Shared

    @ViewBuilder
    private func trailing(controlSize: ControlSize) -> some View {
        if let activity {
            ExtensionActivityView(activity: activity, compact: controlSize == .small)
        } else {
            HStack(spacing: 6) {
                if error != nil, controlSize == .small {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                ExtensionActionButton(state: subject.state, onInstall: onInstall, onRemove: onRemove)
                    .controlSize(controlSize)
            }
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
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 5 : 8) {
            if case .downloading(let fraction?) = activity, !compact {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 100)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(compact ? 0.6 : 1)
                    .frame(width: compact ? 12 : nil, height: compact ? 12 : nil)
            }
            if !compact {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(label)
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
