import SwiftUI

/// How a split reads in a control.
///
/// `SplitViewDirection` is the app's existing word for this — the terminal
/// splits have used it since before the editor existed, and it is already
/// `Codable`. These are the presentation-layer adornments, kept out of it
/// so a type shared with the terminal does not grow an opinion about SF
/// Symbols.
///
/// The names describe the direction the **panes** run in, not the divider's,
/// and the two are perpendicular: `.horizontal` puts the panes side by side,
/// separated by a vertical line. Every bug in this area starts with someone
/// reading it the other way — which is also why the button is labelled with
/// what it *does* rather than with the state it is in.
extension SplitViewDirection {
    var toggled: SplitViewDirection {
        self == .horizontal ? .vertical : .horizontal
    }

    var symbol: String {
        switch self {
        case .horizontal: "rectangle.split.2x1"
        case .vertical: "rectangle.split.1x2"
        }
    }

    var splitActionName: String {
        switch self {
        case .horizontal: "Split Vertically"
        case .vertical: "Split Horizontally"
        }
    }

    /// For `@AppStorage`, which needs a `String` and cannot use `Codable`.
    var storageKey: String {
        self == .horizontal ? "horizontal" : "vertical"
    }

    static func fromStorage(_ raw: String) -> SplitViewDirection {
        raw == "vertical" ? .vertical : .horizontal
    }
}

/// The affordance in the top-right of a file for changing how it is shown.
///
/// Deliberately not a `TabView` or a `Picker(.segmented)`: those announce
/// themselves as chrome and take a strip of the window permanently, and this
/// sits on top of the text a reader is trying to read. It stays faint until
/// pointed at, which is the same bargain the scrollbar makes.
///
/// Renders nothing at all when the document has only one way to be shown —
/// a control whose every press is a no-op is worse than an empty corner.
struct EditorPresentationControl: View {
    let options: EditorPresentationOptions
    @Binding var presentation: EditorPresentation
    @Binding var direction: SplitViewDirection

    @State private var isHovered = false

    var body: some View {
        if options.available.count > 1 {
            HStack(spacing: 1) {
                ForEach(options.available, id: \.self) { option in
                    button(for: option)
                }

                /// Only while split, because orientation is meaningless with
                /// one pane — and showing a dead control next to live ones
                /// teaches people to distrust the whole cluster.
                if presentation == .split {
                    Divider()
                        .frame(height: 12)
                        .padding(.horizontal, 3)

                    directionButton
                }
            }
            .padding(3)
            .background(background)
            .opacity(isHovered ? 1 : 0.4)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .padding(6)
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.thinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
            .opacity(isHovered ? 1 : 0)
    }

    private func button(for option: EditorPresentation) -> some View {
        let isCurrent = presentation == option

        return Button {
            presentation = option
        } label: {
            Image(systemName: symbol(for: option))
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(isCurrent ? 0.12 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        .help(name(for: option))
        .accessibilityLabel(name(for: option))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private var directionButton: some View {
        Button {
            direction = direction.toggled
        } label: {
            Image(systemName: direction.symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.secondary)
        .help(direction.splitActionName)
        .accessibilityLabel(direction.splitActionName)
    }

    private func symbol(for option: EditorPresentation) -> String {
        switch option {
        case .source: "chevron.left.forwardslash.chevron.right"
        case .preview: "doc.richtext"
        case .diff: "plus.forwardslash.minus"
        case .split: direction.symbol
        }
    }

    private func name(for option: EditorPresentation) -> String {
        switch option {
        case .source: "Source"
        case .preview: "Preview"
        case .diff: "Changes"
        case .split: "Split"
        }
    }
}
