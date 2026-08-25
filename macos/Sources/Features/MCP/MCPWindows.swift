import AppKit
import Foundation

/// Which window a tool acts on, and which tab it is talking about.
///
/// The caller's own tab is the anchor. An agent runs inside one terminal of
/// one window, and that window is the one whose editor it may move. Driving
/// the key window instead would put files in front of whatever the reader
/// happened to be looking at — a different window most of the time, since the
/// reason to run an agent in one window is to work in another.
///
/// There is deliberately no fallback for a caller with no tab. A tool that
/// guesses a window acts on the wrong one silently, and silence is the one
/// answer an agent cannot correct; the tools refuse instead, naming the
/// condition that was not met.
@MainActor
enum MCPWindows {
    /// The window whose split tree holds a tab.
    ///
    /// Asked of the tree rather than of the surface's `window`, for the reason
    /// `BaseTerminalController.controller(owning:)` gives: while AppKit
    /// attaches or moves a native tab, a surface's window is briefly nil or
    /// still the previous one.
    static func controller(holding surface: UUID) -> TerminalController? {
        TerminalController.all.first { controller in
            controller.surfaceTree.contains { $0.id == surface }
        }
    }

    /// A tab by id, in whichever window has it.
    ///
    /// Nil is what a closed tab looks like, and what a tab of another Phantom
    /// build looks like. Both are refusals rather than no-ops: an id that
    /// names nothing is a mistake the caller can fix.
    static func surface(_ id: UUID) -> Ghostty.SurfaceView? {
        for controller in TerminalController.all {
            if let surface = controller.surfaceTree.first(where: { $0.id == id }) {
                return surface
            }
        }
        return nil
    }

    /// The editor of the window a caller is sitting in.
    ///
    /// The one seam the editor tools reach the app through, so a test can hand
    /// them an `EditorCenter` of its own and never need a window.
    static func editor(for surface: UUID?) -> EditorCenter? {
        guard let surface else { return nil }
        return controller(holding: surface)?.editorCenter
    }
}
