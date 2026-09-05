import SwiftUI

struct ExtensionsPanelRow: View {
    let name: String
    let version: String
    let detail: String
    let state: ExtensionState
    let isBusy: Bool
    let hasError: Bool
    let action: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(verbatim: name)
                            .font(palette.font(size: 11, weight: .medium))
                            .lineLimit(1)
                        Text(verbatim: version)
                            .font(palette.font(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(verbatim: detail)
                        .font(palette.font(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                trailing

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var trailing: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
        } else if hasError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        } else {
            ExtensionsPanelStateBadge(state: state, showsTitle: false)
        }
    }
}

struct ExtensionsPanelStateBadge: View {
    let state: ExtensionState
    var showsTitle = true

    @ObservedObject private var palette: ThemePalette = .shared

    var body: some View {
        if let mark {
            HStack(spacing: 4) {
                Circle()
                    .fill(mark.color)
                    .frame(width: 7, height: 7)
                if showsTitle {
                    Text(mark.title)
                        .font(palette.font(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var mark: (title: LocalizedStringKey, color: Color)? {
        switch state {
        case .notInstalled: return nil
        case .installed: return ("Installed", .green)
        case .updateAvailable: return ("Update available", .orange)
        }
    }
}

enum ExtensionsPanelText {
    static func version(_ offered: String, state: ExtensionState) -> String {
        if case .updateAvailable(let installed, let available) = state {
            return "\(installed) \u{2192} \(available)"
        }
        return offered
    }

    static func activityLabel(_ activity: ExtensionActivity) -> LocalizedStringKey {
        switch activity {
        case .downloading: return "Downloading…"
        case .verifying: return "Verifying…"
        case .installing: return "Installing…"
        case .removing: return "Removing…"
        }
    }
}
