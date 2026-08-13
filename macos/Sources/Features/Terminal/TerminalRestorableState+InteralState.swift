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
        /// The window's position within its tab group (`tabGroup.windows`
        /// order, selected tab first). Preserves the front-to-back tab order
        /// across a restore.
        let tabIndex: Int?
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(
        from controller: TerminalController,
        tabGroupID: Int? = nil,
        tabIndex: Int? = nil
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
        )
    }
}
