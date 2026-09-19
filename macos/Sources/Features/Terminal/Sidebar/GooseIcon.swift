import SwiftUI

/// The Goose mark, rendered from the bundled template asset.
struct GooseIcon: View {
    var size: CGFloat = 12
    var tint: Color = .secondary
    var originalColors = false

    var body: some View {
        Image("GooseIcon")
            .renderingMode(originalColors ? .original : .template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(originalColors ? .primary : tint)
    }
}