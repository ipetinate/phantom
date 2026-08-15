import SwiftUI

/// The OpenCode mark. It is neutral in the terminal UI and keeps its source
/// colors in the Agents settings screen.
struct OpenCodeIcon: View {
    var size: CGFloat = 12
    var tint: Color = .secondary
    var originalColors = false

    var body: some View {
        Image("OpenCodeIcon")
            .renderingMode(originalColors ? .original : .template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(originalColors ? .primary : tint)
    }
}
