import SwiftUI

/// The Kilo Code mark, rendered from the bundled template asset.
struct KiloIcon: View {
    var size: CGFloat = 12
    var tint: Color = .secondary
    var originalColors = false

    var body: some View {
        Image("KiloIcon")
            .renderingMode(originalColors ? .original : .template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(originalColors ? .primary : tint)
    }
}