import AppKit

extension TerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        // MARK: - Phantom (own session store)
        /// The window frame at save time. macOS's own saved state tracks
        /// the frame itself; our store persists it so restored windows land
        /// where they were.
        let frame: CGRect?

        // MARK: - Phantom (own session store, tab groups)
        /// Identifies the window's tab group, if it was one of several tabs
        /// sharing a window. Windows with the same `tabGroupID` are restored
        /// as tabs of a single window; `nil` restores a standalone window.
        let tabGroupID: Int?
        /// The window's position within its tab group, in `tabGroup.windows`
        /// order — which is the order the tabs sit in the tab bar, left to
        /// right. Preserves the tab order across a restore.
        let tabIndex: Int?

        /// Whether this tab was the one the window was showing.
        ///
        /// A separate question from `tabIndex`, which is only the tab's
        /// place in the bar: `NSWindowTabGroup.selectedWindow` is its own
        /// property and no order in `tabGroup.windows` implies it. Without
        /// this, a restored window came back on its first tab however far
        /// along the bar the reader had actually been working.
        ///
        /// Optional so a `session.json` written before it existed still
        /// decodes; `nil` everywhere means "no recorded selection", and the
        /// restore falls back to the first tab.
        let isSelectedTab: Bool?

        /// Whether the window was actually in fullscreen.
        ///
        /// `effectiveFullscreenMode` cannot answer this and never could: a
        /// controller is given a `NativeFullscreen` style the moment its
        /// window loads (`BaseTerminalController.windowDidLoad`), so the
        /// mode reads `.native` for every window ever opened, fullscreen or
        /// not. A live `session.json` recording `"effectiveFullscreenMode":
        /// "native"` for a 951x600 window is the proof. Restoring on the
        /// strength of the mode alone therefore forced ordinary windows into
        /// fullscreen and, by the same token, made the saved frame look like
        /// fullscreen bounds and get skipped — so a window came back
        /// fullscreen at a size it had never had.
        ///
        /// Optional for the same reason as `isSelectedTab`: sessions written
        /// before it existed still decode, and `nil` is read as "not
        /// fullscreen", which is what all but a few windows were.
        let isFullscreen: Bool?

        // MARK: - Phantom (own session store, editor)

        /// What the window's editor had open: the cells, the tabs in each,
        /// and which one was in front.
        ///
        /// Beside the surface tree rather than in a file of its own, because
        /// it belongs to the same window and has to come and go with it. A
        /// second file would need a key tying it to this window, and the only
        /// honest key — the terminal the editor took its pane from — is
        /// already what this record *is*.
        ///
        /// Optional for the reason the fields above are, and for one more: it
        /// is nil for every window whose editor never opened a file, which is
        /// most of them.
        let editorGrid: EditorGridState?
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(
        from controller: TerminalController,
        tabGroupID: Int? = nil,
        tabIndex: Int? = nil,
        isSelectedTab: Bool? = nil
    ) {
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: (controller.window as? TerminalWindow)?.tabColor,
            titleOverride: controller.titleOverride,
            frame: controller.window?.frame,
            tabGroupID: tabGroupID,
            tabIndex: tabIndex,
            isSelectedTab: isSelectedTab,
            isFullscreen: controller.fullscreenStyle?.isFullscreen,
            /// The editor is main-actor isolated and this initializer is not,
            /// though every caller reaches it from the main thread: both
            /// `PhantomSessionStore.saveNow` call sites are AppKit's
            /// termination handlers, its third is a `DispatchQueue.main`
            /// work item, and `window(_:willEncodeRestorableState:)` is a
            /// window delegate callback. Asserted rather than hopped, because
            /// a hop would make the capture asynchronous and the save would
            /// then record the arrangement as it is *after* whatever prompted
            /// the save.
            ///
            /// The thread is checked first because `assumeIsolated` is a
            /// precondition, not a question: reached off the main thread it
            /// does not return an error, it kills the process. Nothing in the
            /// list above is off the main thread today, and none of it is
            /// enforced by a type. One of those callers runs inside quit,
            /// where an abort would take the session file and the undo
            /// history down with it — so an impossible thread is answered
            /// with no editor state rather than no app.
            editorGrid: Thread.isMainThread
                ? MainActor.assumeIsolated { EditorGridState(capturing: controller.editorCenter) }
                : nil,
        )
    }
}
