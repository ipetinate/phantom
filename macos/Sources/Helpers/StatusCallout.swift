import SwiftUI

/// A small framed message inside a form or sheet: an icon and title on the
/// first line, the explanation under them, and — when the state is a moment
/// rather than a fact — a dismiss.
///
/// Three kinds, one shape, so a sheet's information, warnings and failures
/// all read as the same species at different temperatures. The dismiss is
/// optional on purpose: an error the user can clear takes the X; a warning
/// that merely restates the current input does not, because it disappears by
/// itself the moment the input changes, and an X on it would promise more
/// than it does.
struct StatusCallout: View {
    enum Kind {
        case info
        case warning
        case error

        var color: Color {
            switch self {
            case .info: return .blue
            case .warning: return .orange
            case .error: return .red
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    let kind: Kind
    let title: String
    var message: String?
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kind.color)

                Text(verbatim: title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(2)

                Spacer(minLength: 4)

                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }

            if let message, !message.isEmpty {
                Text(verbatim: message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(kind.color.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(kind.color.opacity(0.35), lineWidth: 1)
        )
    }
}
