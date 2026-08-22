import Combine
import Foundation

/// Where the terminal that owns the editor's pane currently is.
///
/// One published string, and a type of its own because of where it has to be
/// readable from. The pane is SwiftUI hosted inside an AppKit window, and the
/// working directory is AppKit state the shell rewrites every time it `cd`s
/// — so a view that read it once, or reached for the key window while
/// rendering, would keep showing an answer from a directory the reader has
/// left. ``EditorCenter/terminalTitle`` is the same seam for the same
/// reason; the difference is only that a title is decoration and this
/// decides whether an open file is shown as belonging to another checkout.
///
/// Per window, like the centre beside it: the pane belongs to one terminal,
/// and "which worktree am I in" is that terminal's answer and nobody else's.
@MainActor
final class EditorTerminalDirectory: ObservableObject {
    /// Nil until the shell has reported one.
    ///
    /// Nil rather than a guess, and the home directory in particular. A
    /// surface that has never sent OSC 7 has no working directory to speak
    /// of, and substituting one would put every open file in "another
    /// checkout" — a divergence banner over every tab in the window, on the
    /// strength of a directory nobody is in.
    @Published var path: String?
}
