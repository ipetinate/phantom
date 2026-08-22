import AppKit
import SwiftUI

/// Typing an `@file:line` reference into a terminal's prompt.
///
/// The seam between the editor and the terminal is the window: the editor
/// takes over a terminal tab's pane, and both belong to the same
/// `TerminalController`. Resolving through the key window is the established
/// reach-up (`TerminalPathRouter` does the same), and it is correct here by
/// construction — ⌘K only fires while the editor has focus, so the key window
/// is the one the editor lives in.
@MainActor
enum AgentAttach {
    /// The terminal of the tab the editor belongs to.
    ///
    /// `focusedSurface` survives the editor being first responder — it is only
    /// cleared when the surface tree empties — so this is "the terminal you
    /// came from", not "whatever has focus now".
    static func ownSurface() -> Ghostty.SurfaceView? {
        guard let controller = NSApp.keyWindow?.windowController as? TerminalController
        else { return nil }
        return controller.focusedSurface ?? controller.surfaceTree.root?.leftmostLeaf()
    }

    static func ownCwd() -> String? {
        (NSApp.keyWindow?.windowController as? TerminalController)?.workingDirectoryForPaths
    }

    /// Types the reference, without submitting it.
    ///
    /// `sendText` has paste semantics: under bracketed paste — which every
    /// interactive shell and agent TUI keeps on — nothing here can press
    /// Enter, which is the point. The trailing space is what lets the reader
    /// keep typing their question immediately after the reference.
    static func send(_ reference: String, into surface: Ghostty.SurfaceView) {
        surface.surfaceModel?.sendText(reference + " ")
    }

    /// Every terminal in the app, for the picker.
    ///
    /// Enumerated the way the command palette's jump list does it: every
    /// controller, every leaf of its surface tree. The agent name comes from
    /// the tab-state records so a row can say what is listening on it.
    static func targets() -> [Target] {
        var found: [Target] = []
        for controller in TerminalController.all {
            guard let tree = controller.surfaceTree.root else { continue }
            for surface in tree.leaves() {
                let record = TabStateCenter.shared.records[surface.id]
                let title = controller.titleOverride
                    ?? (surface.title.isEmpty ? nil : surface.title)
                    ?? controller.window?.title
                    ?? "Terminal"
                found.append(Target(
                    surface: surface,
                    title: title,
                    pwd: surface.pwd,
                    agentName: record?.liveAgent?.displayName,
                    window: controller.window))
            }
        }
        return found
    }

    struct Target: Identifiable {
        let surface: Ghostty.SurfaceView
        let title: String
        let pwd: String?
        let agentName: String?
        let window: NSWindow?

        var id: UUID { surface.id }
    }

    /// Sends to a picked target and brings its window forward — a reference
    /// typed into an invisible terminal looks like nothing happened.
    static func send(_ referenceFor: (String?) -> String, to target: Target) {
        let reference = referenceFor(target.pwd)
        send(reference, into: target.surface)
        target.window?.makeKeyAndOrderFront(nil)
    }
}
