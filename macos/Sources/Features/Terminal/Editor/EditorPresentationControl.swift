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
            .padding(4)
            .background(background)
            .opacity(isHovered ? 1 : 0.78)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .padding(6)
        }
    }

    /// Always drawn, which is the whole difference between a control you
    /// can find and one you have to know about.
    ///
    /// It used to appear only on hover, so at rest the glyphs floated
    /// unbacked over whatever the editor happened to be drawing — and the
    /// place it sits is beside the minimap, which is the busiest, most
    /// multicoloured strip in the window. Contrast cannot come from the
    /// glyph alone when the thing behind it is arbitrary.
    ///
    /// `.regularMaterial` rather than `.thinMaterial`: thin lets the code
    /// underneath read straight through, which is the property that made
    /// this hard to see. The extra wash on hover is the affordance now,
    /// rather than the background's whole existence.
    private var background: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.22 : 0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
    }

    private func button(for option: EditorPresentation) -> some View {
        let isCurrent = presentation == option

        return Button {
            presentation = option
        } label: {
            Image(systemName: symbol(for: option))
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 27, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isCurrent ? 0.18 : 0))
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
        /// Lines of text with a change marked against them, which is what a
        /// source file's diff actually shows. Not `plus.forwardslash.minus`,
        /// which was here first and reads as a percent sign, and not a swap
        /// arrow, which would say "switch" — ambiguous next to buttons whose
        /// whole job is switching.
        case .diff: "text.append"
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
