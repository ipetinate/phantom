import SwiftUI

/// The Codex mark, rendered from the bundled template asset.
struct CodexIcon: View {
    var size: CGFloat = 12
    var tint: Color = .secondary
    var originalColors = false

    var body: some View {
        Image("CodexIcon")
            .renderingMode(originalColors ? .original : .template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(originalColors ? .primary : tint)
    }
}
