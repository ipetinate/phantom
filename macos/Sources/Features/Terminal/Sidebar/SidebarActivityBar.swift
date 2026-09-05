import SwiftUI

struct SidebarActivityBar: View {
    @Binding var selection: SidebarPane

    let panes: [SidebarPane]

    @ObservedObject private var palette: ThemePalette = .shared

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(panes) { pane in
                chip(for: pane)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .frame(width: SidebarIconChipMetrics.width + 8)
    }

    private func chip(for pane: SidebarPane) -> some View {
        let isSelected = selection == pane

        return SidebarIconButton(help: pane.title) {
            guard selection != pane else { return }
            withAnimation(.easeOut(duration: 0.12)) { selection = pane }
        } label: {
            SidebarPaneIcon(pane: pane, size: 13)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
        .background(
            RoundedRectangle(cornerRadius: SidebarIconChipMetrics.cornerRadius)
                .fill(isSelected ? accent.opacity(0.22) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent)
                    .frame(width: 2)
                    .padding(.vertical, 5)
            }
        }
    }
}
