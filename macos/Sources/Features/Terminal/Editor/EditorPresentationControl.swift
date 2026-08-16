import SwiftUI

/// Remembering how the reader likes their splits cut.
///
/// `SplitViewDirection` is `Codable`, which `@AppStorage` cannot use — it
/// wants a `String`. Only the storage spelling lives here: the symbol and
/// the tooltip belong to `SplitPaneDirectionToggle`, which draws the actual
/// button inside the split container, and a second opinion about either
/// would be a second thing to keep in step.
extension SplitViewDirection {
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

    @State private var isHovered = false

    var body: some View {
        if options.available.count > 1 {
            HStack(spacing: 1) {
                ForEach(options.available, id: \.self) { option in
                    button(for: option)
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

    private func symbol(for option: EditorPresentation) -> String {
        switch option {
        case .source: "chevron.left.forwardslash.chevron.right"
        case .preview: "doc.richtext"
        case .diff: "plus.forwardslash.minus"
        case .split: "rectangle.split.2x1"
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
