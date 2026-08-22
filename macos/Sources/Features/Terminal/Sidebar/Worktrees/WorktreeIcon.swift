import SwiftUI

/// The worktree mark: a branch network, wherever the sidebar says "this
/// branch lives in a worktree of its own".
///
/// A template image for the same reason `GitIcon` is one — the sidebar's
/// glyphs are a monochrome set that follows the terminal theme, and template
/// rendering uses the artwork's alpha with whatever `foregroundStyle` is in
/// effect, so the stroke colour in the file is irrelevant.
struct WorktreeIcon: View {
    var size: CGFloat = 12

    var body: some View {
        Image("WorktreeIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
