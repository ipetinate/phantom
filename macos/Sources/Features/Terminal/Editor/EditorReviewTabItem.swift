import SwiftUI

/// The review's tab in a cell's strip.
///
/// Its own type rather than an `EditorTabItem` with a fake `EditorTab`: that
/// type is built around a path — it shows a file icon, a directory when two
/// names collide, a dirty dot, and a menu of file commands — and a review has
/// none of those. Faking a path to reuse the row would put a review one bug
/// away from being treated as a file by anything that reads `tab.path`.
struct EditorReviewTabItem: View {
    let title: String

    /// What the tooltip says. Passed in rather than fixed, because the tab is
    /// no longer always the branch: a cell can hold one tab per commit, and
    /// "The branch review" on all of them would name none of them.
    var help: String = "The branch review"
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @State private var isHovered = false

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? accent : .secondary)

            Text(title)
                .font(palette.font(size: 11, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            /// Present only on hover or when selected, like the file tabs'
            /// own close button: a row of permanent × in a strip of tabs is a
            /// row of things to click by accident.
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Rectangle()
                .fill(isSelected ? accent.opacity(0.14) : .clear))
        .overlay(alignment: .bottom) {
            /// The selected tab's underline, the same one the file tabs draw.
            Rectangle()
                .fill(isSelected ? accent : .clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
