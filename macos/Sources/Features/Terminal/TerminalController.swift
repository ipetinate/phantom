import Foundation
import Cocoa
import SwiftUI
import Combine
import GhosttyKit

/// A classic, tabbed terminal experience.
class TerminalController: BaseTerminalController, TabGroupCloseCoordinator.Controller, NSSplitViewDelegate {
    override var windowNibName: NSNib.Name? {
        let defaultValue = "Terminal"

        guard let appDelegate = NSApp.delegate as? AppDelegate else { return defaultValue }
        let config = appDelegate.ghostty.config

        // If we have no window decorations, there's no reason to do anything but
        // the default titlebar (because there will be no titlebar).
        if !config.windowDecorations {
            return defaultValue
        }

        let nib = switch config.macosTitlebarStyle {
        case .native: "Terminal"
        case .hidden: "TerminalHiddenTitlebar"
        case .transparent: "TerminalTransparentTitlebar"
        case .tabs:
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                "TerminalTabsTitlebarTahoe"
            } else {
                "TerminalTabsTitlebarVentura"
            }
#else
            "TerminalTabsTitlebarVentura"
#endif
        }

        return nib
    }

    /// This is set to true when we care about frame changes. This is a small optimization since
    /// this controller registers a listener for ALL frame change notifications and this lets us bail
    /// early if we don't care.
    private var tabListenForFrame: Bool = false

    /// This is the hash value of the last tabGroup.windows array. We use this to detect order
    /// changes in the list.
    private var tabWindowsHash: Int = 0

    /// The initial window presentation is deferred by one runloop turn in a few places so
    /// AppKit can settle tab/window state first. Close actions must cancel it to avoid
    /// re-showing a tab that was already closed.
    private var pendingInitialPresentation: DispatchWorkItem?

    /// This is set to false by init if the window managed by this controller should not be restorable.
    /// For example, terminals executing custom scripts are not restorable.
    private var restorable: Bool = true

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig

    /// The notification cancellable for focused surface property changes.
    private var surfaceAppearanceCancellables: Set<AnyCancellable> = []

    /// The tab read-model backing the sidebar, when the sidebar is enabled.
    private(set) var sidebarTabManager: SidebarTabManager?

    /// The split view hosting the sidebar, kept to sync divider position
    /// across all windows in the tab group.
    private var sidebarSplitView: NSSplitView?

    /// Layout state shared with the sidebar view (collapse, actions).
    private var sidebarLayout: SidebarLayoutModel?
    private var sidebarLayoutCancellable: AnyCancellable?

    /// The files open in this window's pane. One per window, because the
    /// editor takes over *this* terminal's half of the split.
    let editorCenter = EditorCenter()

    /// Search across the folder the explorer is showing, opened with ⇧⌘F.
    let workspaceSearch = WorkspaceSearchCenter()

    /// Where this window's terminal is, for the pane above it. See
    /// ``EditorTerminalDirectory``.
    let editorTerminalDirectory = EditorTerminalDirectory()
    private var editorTerminalDirectoryCancellable: AnyCancellable?
    private var editorHostingView: NSView?

    /// The terminal half of the right pane, hidden while the editor has
    /// the floor.
    private weak var terminalPaneView: NSView?
    private var editorCancellable: AnyCancellable?
    private var terminalTitleCancellable: AnyCancellable?

    /// The pane tab bar, coloured with the rest of the pane.
    private weak var paneTabBarView: NSView?

    /// The pane tab bar's height constraint, zero while no file is open.
    private var paneTabBarHeight: NSLayoutConstraint?

    /// The bar's own height: the tab row, the strip its scroller draws in,
    /// and the divider under both. Derived rather than written out, so
    /// changing the row's height cannot leave the terminal overlapping it.
    private static let paneTabBarHeightWhenShown: CGFloat = EditorTabBar.height + 1

    /// Width constraints swapped when the sidebar collapses.
    private var sidebarExpandedConstraints: [NSLayoutConstraint] = []
    private var sidebarCollapsedConstraint: NSLayoutConstraint?

    /// The sidebar hosting view, tinted with the terminal's effective
    /// background (color + opacity) so both panes always match.
    private var sidebarBackgroundView: NSView?

    /// Fills the titlebar strip over the terminal pane, which the terminal's
    /// own content doesn't reach.
    private var terminalTitlebarFiller: NSView?

    /// The two constraints that place the right pane's chrome against the
    /// titlebar strip: the filler's bottom edge and the pane tab bar's top.
    ///
    /// Both are offset from the terminal's safe area by whatever part of the
    /// strip the window has stopped reserving, which is zero for an ordinary
    /// window and the strip's height in native fullscreen. See
    /// `syncTitlebarStripInsets`.
    private var terminalTitlebarFillerBottom: NSLayoutConstraint?
    private var paneTabBarTopConstraint: NSLayoutConstraint?

    /// The sidebar pane container and its glass layer (glass effect
    /// modes cover every pane, so the sidebar carries its own).
    private weak var sidebarPane: NSView?

    /// The sidebar action icons, added straight into the titlebar
    /// container and centered on the traffic lights; the trailing
    /// constraint tracks the sidebar so the icons hug the divider.
    private var sidebarChromeView: NSView?
    private var sidebarChromeTrailingConstraint: NSLayoutConstraint?

    /// The config fallback width used before any user drag is persisted.
    /// The width a sidebar opens at when the reader has never dragged one
    /// and the config does not say.
    ///
    /// Raised from 240, which is where a group row starts losing its name to
    /// the controls beside it — the layout survives that now, but a default
    /// that needs truncation to be readable is the wrong default. This is
    /// only the fallback: `config.sidebarWidth` still wins, and so does any
    /// width dragged to since.
    private var sidebarDefaultWidth: CGFloat = 280

    /// UserDefaults key holding the app-wide sidebar width. Shared by all
    /// windows so dragging the divider in one tab applies to every tab.
    static let sidebarWidthDefaultsKey = "GhosttySidebarWidth"

    init(_ ghostty: Ghostty.App,
         withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
         withSurfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil,
         parent: NSWindow? = nil
    ) {
        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        self.restorable = (base?.command ?? "") == ""

        // Setup our initial derived config based on the current app config
        self.derivedConfig = DerivedConfig(ghostty.config)

        super.init(ghostty, baseConfig: base, surfaceTree: tree)

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onMoveTab),
            name: .ghosttyMoveTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTab),
            name: .ghosttyCloseTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseOtherTabs),
            name: .ghosttyCloseOtherTabs,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTabsOnTheRight),
            name: .ghosttyCloseTabsOnTheRight,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onResetWindowSize),
            name: .ghosttyResetWindowSize,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseWindow),
            name: .ghosttyCloseWindow,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)
    }

    private func cancelPendingInitialPresentation() {
        pendingInitialPresentation?.cancel()
        pendingInitialPresentation = nil
    }

    private func scheduleInitialPresentation(_ block: @escaping () -> Void) {
        cancelPendingInitialPresentation()

        var scheduledWorkItem: DispatchWorkItem?
        scheduledWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer { self.pendingInitialPresentation = nil }
            guard pendingInitialPresentation?.isCancelled == false else { return }
            block()
        }

        let workItem = scheduledWorkItem!
        pendingInitialPresentation = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    // MARK: Base Controller Overrides

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)

        // Whenever our surface tree changes in any way (new split, close split, etc.)
        // we want to invalidate our state.
        invalidateRestorableState()

        // Keep our own session store in sync with the current window set.
        PhantomSessionStore.shared.scheduleSave()

        // Update our zoom state
        if let window = window as? TerminalWindow {
            window.surfaceIsZoomed = to.zoomed != nil
        }

        // If our surface tree is now nil then we close our window.
        if to.isEmpty {
            self.window?.close()
        }
    }

    override func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // We have a special case if our tree is empty to close our tab immediately.
        // This makes it so that undo is handled properly.
        if newTree.isEmpty {
            closeTabImmediately()
            return
        }

        super.replaceSurfaceTree(
            newTree,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: undoAction)
    }

    // MARK: Terminal Creation

    /// Returns all the available terminal controllers present in the app currently.
    static var all: [TerminalController] {
        return NSApplication.shared.windows.compactMap {
            $0.windowController as? TerminalController
        }
    }

    /// Whether any terminal window is actually on screen.
    ///
    /// Emphatically not `!all.isEmpty`. `NSApplication.windows` includes
    /// windows that exist and are not visible, so a controller whose window
    /// was created and never ordered front counts towards `all` while
    /// showing the reader nothing. Anything asking "does this app have a
    /// window" to decide whether to *open* one has to ask about visibility,
    /// or it answers yes to an empty screen and declines to fix it.
    static var hasVisibleWindow: Bool {
        all.contains { $0.window?.isVisible == true }
    }

    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)

    private static func applyCascade(to window: NSWindow, hasFixedPos: Bool) {
        if hasFixedPos { return }

        /// Cascading and centring are the same decision made twice, and they
        /// disagree: `showWindow` now opens a standalone window in the middle
        /// of its screen, and stepping it down and right immediately
        /// afterwards would undo that on the second window and every one
        /// after it.
        ///
        /// Kept rather than deleted, and gated here rather than at its two
        /// call sites, so there is one place to look and one line to remove
        /// if staggered windows are wanted back — and so the shape upstream
        /// merges against stays recognisable.
        if opensCentred { return }

        if all.count > 1 {
            lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
        } else {
            // We assume the window frame is already correct at this point,
            // so we pass .zero to let cascade use the current frame position.
            lastCascadePoint = window.cascadeTopLeft(from: .zero)
        }
    }

    // The preferred parent terminal controller.
    static var preferredParent: TerminalController? {
        all.first {
            $0.window?.isMainWindow ?? false
        } ?? lastMain ?? all.last
    }

    // The last controller to be main. We use this when paired with "preferredParent"
    // to find the preferred window to attach new tabs, perform actions, etc. We
    // always prefer the main window but if there isn't any (because we're triggered
    // by something like an App Intent) then we prefer the most previous main.
    static private(set) weak var lastMain: TerminalController?

    /// The "new window" action.
    static func newWindow(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        withParent explicitParent: NSWindow? = nil
    ) -> TerminalController {
        let c = TerminalController.init(ghostty, withBaseConfig: baseConfig)

        // Get our parent. Our parent is the one explicitly given to us,
        // otherwise the focused terminal, otherwise an arbitrary one.
        let parent: NSWindow? = explicitParent ?? preferredParent?.window
        if let parentController = parent?.windowController as? TerminalController {
            c.isBackgroundOpaque = parentController.isBackgroundOpaque
        }

        if let parent, parent.styleMask.contains(.fullScreen) {
            // If our previous window was fullscreen then we want our new window to
            // be fullscreen. This behavior actually doesn't match the native tabbing
            // behavior of macOS apps where new windows create tabs when in native
            // fullscreen but this is how we've always done it. This matches iTerm2
            // behavior.
            c.toggleFullscreen(mode: .native)
        } else if let fullscreenMode = ghostty.config.windowFullscreen {
            switch fullscreenMode {
            case .native:
                // Native has to be done immediately so that our stylemask contains
                // fullscreen for the logic later in this method.
                c.toggleFullscreen(mode: .native)

            case .nonNative, .nonNativeVisibleMenu, .nonNativePaddedNotch:
                // If we're non-native then we have to do it on a later loop
                // so that the content view is setup.
                DispatchQueue.main.async {
                    c.toggleFullscreen(mode: fullscreenMode)
                }
            }
        }

        // We're dispatching this async because otherwise the lastCascadePoint doesn't
        // take effect. Our best theory is there is some next-event-loop-tick logic
        // that Cocoa is doing that we need to be after.
        c.scheduleInitialPresentation {
            c.showWindow(self)

            // Only cascade if we aren't fullscreen.
            if let window = c.window {
                if !window.styleMask.contains(.fullScreen) {
                    let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                    Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                }
            }

            // All new_window actions force our app to be active, so that the new
            // window is focused and visible.
            NSApp.activate(ignoringOtherApps: true)
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                // Close the window when undoing
                undoManager.disableUndoRegistration {
                    target.closeWindow(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        withBaseConfig: baseConfig,
                        withParent: explicitParent)
                }
            }
        }

        return c
    }

    /// Create a new window with an existing split tree.
    /// The window will be sized to match the tree's current view bounds if available.
    /// - Parameters:
    ///   - ghostty: The Ghostty app instance.
    ///   - tree: The split tree to use for the new window.
    ///   - position: Optional screen position (top-left corner) for the new window.
    ///               If nil, the window will cascade from the last cascade point.
    static func newWindow(
        _ ghostty: Ghostty.App,
        tree: SplitTree<Ghostty.SurfaceView>,
        position: NSPoint? = nil,
        confirmUndo: Bool = true,
        inheritBackgroundOpacity: Bool? = nil
    ) -> TerminalController {
        // Calculate the target frame based on the tree's view bounds
        // before moving into the new window
        let treeSize: CGSize? = tree.root?.viewBounds()

        let c = TerminalController.init(ghostty, withSurfaceTree: tree)
        if let inheritBackgroundOpacity {
            c.isBackgroundOpaque = inheritBackgroundOpacity
        }

        c.scheduleInitialPresentation {
            c.showWindow(self)
            if let window = c.window {
                // If we have a tree size, resize the window's content to match
                if let treeSize, treeSize.width > 0, treeSize.height > 0 {
                    window.setContentSize(treeSize)
                    window.constrainToScreen()
                }

                if !window.styleMask.contains(.fullScreen) {
                    if let position {
                        window.setFrameTopLeftPoint(position)
                        window.constrainToScreen()
                    } else {
                        let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                        Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                    }
                }
            }
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                undoManager.disableUndoRegistration {
                    if confirmUndo {
                        target.closeWindow(nil)
                    } else {
                        target.closeWindowImmediately()
                    }
                }

                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        tree: tree,
                        inheritBackgroundOpacity: inheritBackgroundOpacity
                    )
                }
            }
        }

        return c
    }

    static func newTab(
        _ ghostty: Ghostty.App,
        from parent: NSWindow? = nil,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> TerminalController? {
        // Making sure that we're dealing with a TerminalController. If not,
        // then we just create a new window.
        guard let parent,
              let parentController = parent.windowController as? TerminalController else {
            return newWindow(ghostty, withBaseConfig: baseConfig, withParent: parent)
        }

        // If our parent is in non-native fullscreen, then new tabs do not work.
        // See: https://github.com/mitchellh/ghostty/issues/392
        if let fullscreenStyle = parentController.fullscreenStyle,
           fullscreenStyle.isFullscreen && !fullscreenStyle.supportsTabs {
            let alert = NSAlert()
            alert.messageText = "Cannot Create New Tab"
            alert.informativeText = "New tabs are unsupported while in non-native fullscreen. Exit fullscreen and try again."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .warning
            alert.beginSheetModal(for: parent)
            return nil
        }

        // Create a new window and add it to the parent
        let controller = TerminalController.init(ghostty, withBaseConfig: baseConfig)
        controller.isBackgroundOpaque = parentController.isBackgroundOpaque
        guard let window = controller.window else { return controller }

        // If the parent is miniaturized, then macOS exhibits really strange behaviors
        // so we have to bring it back out.
        if parent.isMiniaturized { parent.deminiaturize(self) }

        // If our parent tab group already has this window, macOS added it and
        // we need to remove it so we can set the correct order in the next line.
        // If we don't do this, macOS gets really confused and the tabbedWindows
        // state becomes incorrect.
        //
        // At the time of writing this code, the only known case this happens
        // is when the "+" button is clicked in the tab bar.
        if let tg = parent.tabGroup,
           tg.windows.firstIndex(of: window) != nil {
            tg.removeWindow(window)
        }

        // If we don't allow tabs then we create a new window instead.
        if window.tabbingMode != .disallowed {
            // Add the window to the tab group and show it.
            switch ghostty.config.windowNewTabPosition {
            case "end":
                // If we already have a tab group and we want the new tab to open at the end,
                // then we use the last window in the tab group as the parent.
                if let last = parent.tabGroup?.windows.last {
                    last.addTabbedWindowSafely(window, ordered: .above)
                } else {
                    fallthrough
                }

            case "current": fallthrough
            default:
                parent.addTabbedWindowSafely(window, ordered: .above)
            }
        }

        // We're dispatching this async because otherwise the lastCascadePoint doesn't
        // take effect. Our best theory is there is some next-event-loop-tick logic
        // that Cocoa is doing that we need to be after.
        controller.scheduleInitialPresentation {
            // Only cascade if we aren't fullscreen and are alone in the tab group.
            if !window.styleMask.contains(.fullScreen) &&
                window.tabGroup?.windows.count ?? 1 == 1 {
                let hasFixedPos = controller.derivedConfig.windowPositionX != nil && controller.derivedConfig.windowPositionY != nil
                Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
            }

            // showWindow makes regular windows key and ordered front. AppKit can
            // throw while selecting a tab if its fullscreen stack is inconsistent,
            // so this must cross the Objective-C exception bridge.
            controller.showWindowSafely(self)

            // We also activate our app so that it becomes front. This may be
            // necessary for the dock menu.
            NSApp.activate(ignoringOtherApps: true)
        }

        // It takes an event loop cycle until the macOS tabGroup state becomes
        // consistent which causes our tab labeling to be off when the "+" button
        // is used in the tab bar. This fixes that. If we can find a more robust
        // solution we should do that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            controller.relabelTabs()
        }

        // Setup our undo
        if let undoManager = parentController.undoManager {
            undoManager.setActionName("New Tab")
            undoManager.registerUndo(
                withTarget: controller,
                expiresAfter: controller.undoExpiration
            ) { target in
                // Close the tab when undoing
                undoManager.disableUndoRegistration {
                    target.closeTab(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newTab(
                        ghostty,
                        from: parent,
                        withBaseConfig: baseConfig)
                }
            }
        }

        return controller
    }

    // MARK: - Methods

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // Any config reload (settings window, CLI action, file edit)
        // re-resolves the sidebar treatments once the surface state
        // settles — never only the settings-window path.
        if sidebarChromeView != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.syncSidebarBackground()
                self?.attachSidebarChrome()
                (self?.window as? TerminalWindow)?.ensureSidebarTitlebarDecorations()
                self?.sidebarSplitView?.needsDisplay = true
            }
        }

        // If this is an app-level config update then we update some things.
        if notification.object == nil {
            // Update our derived config
            self.derivedConfig = DerivedConfig(config)

            // If we have no surfaces in our window (is that possible?) then we update
            // our window appearance based on the root config. If we have surfaces, we
            // don't call this because focused surface changes will trigger appearance updates.
            if surfaceTree.isEmpty {
                syncAppearance(.init(config))
            }

            return
        }
        /// Surface-level config will be updated in
        /// ``Ghostty/Ghostty/SurfaceView/derivedConfig`` then
        /// ``TerminalController/focusedSurfaceDidChange(to:)``
    }

    /// Update the accessory view of each tab according to the keyboard
    /// shortcut that activates it (if any). This is called when the key window
    /// changes, when a window is closed, and when tabs are reordered
    /// with the mouse.
    func relabelTabs() {
        // We only listen for frame changes if we have more than 1 window,
        // otherwise the accessory view doesn't matter.
        tabListenForFrame = window?.tabbedWindows?.count ?? 0 > 1

        if let windows = window?.tabbedWindows as? [TerminalWindow] {
            for (tab, window) in zip(1..., windows) {
                // We need to clear any windows beyond this because they have had
                // a keyEquivalent set previously.
                guard tab <= 9 else {
                    window.keyEquivalent = ""
                    continue
                }

                if let equiv = ghostty.config.keyboardShortcut(for: "goto_tab:\(tab)") {
                    window.keyEquivalent = "\(equiv)"
                } else {
                    window.keyEquivalent = ""
                }
            }
        }
    }

    private func fixTabBar() {
        // We do this to make sure that the tab bar will always re-composite. If we don't,
        // then the it will "drag" pieces of the background with it when a transparent
        // window is moved around.
        //
        // There might be a better way to make the tab bar "un-lazy", but I can't find it.
        if let window = window, !window.isOpaque {
            window.isOpaque = true
            window.isOpaque = false
        }
    }

    @objc private func onFrameDidChange(_ notification: NSNotification) {
        // This is a huge hack to set the proper shortcut for tab selection
        // on tab reordering using the mouse. There is no event, delegate, etc.
        // as far as I can tell for when a tab is manually reordered with the
        // mouse in a macOS-native tab group, so the way we detect it is setting
        // the accessoryView "postsFrameChangedNotification" to true, listening
        // for the view frame to change, comparing the windows list, and
        // relabeling the tabs.
        guard tabListenForFrame else { return }
        guard let v = self.window?.tabbedWindows?.hashValue else { return }
        guard tabWindowsHash != v else { return }
        tabWindowsHash = v
        self.relabelTabs()
    }

    override func syncAppearance() {
        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)

        // Appearance syncs can rebuild titlebar contents (e.g. after a
        // theme change); make sure the sidebar's titlebar UI survives
        // and the sidebar tint tracks the terminal background.
        if sidebarChromeView != nil {
            DispatchQueue.main.async { [weak self] in
                self?.attachSidebarChrome()
                self?.syncSidebarBackground()
                (self?.window as? TerminalWindow)?.ensureSidebarTitlebarDecorations()
            }
        }
    }

    /// Posted by settings when the sidebar tint changes.
    static let sidebarTintDidChange = Notification.Name("PhantomSidebarTintDidChange")

    /// The sidebar's background treatment is resolved centrally by
    /// AppearanceCoordinator so every blur/opacity/mode combination is
    /// decided in one place.
    private func syncSidebarBackground() {
        let paneColor = AppearanceCoordinator.sidebarLayerColor(
            window: window as? TerminalWindow
        )

        terminalTitlebarFiller?.layer?.backgroundColor = paneColor?.cgColor
        editorHostingView?.layer?.backgroundColor = paneColor?.cgColor
        paneTabBarView?.layer?.backgroundColor = paneColor?.cgColor

        guard let sidebarBackgroundView else { return }
        sidebarBackgroundView.layer?.backgroundColor = paneColor?.cgColor
    }

    /// The window's private corner radius, safely probed.
    private func windowCornerRadiusValue() -> CGFloat? {
        guard let window, window.responds(to: Selector(("_cornerRadius")))
        else { return nil }
        return window.value(forKey: "_cornerRadius") as? CGFloat
    }

    /// Masks the first presentation of this window's terminal pane: the
    /// Metal surface takes a few frames to draw its first content, and
    /// until then the near-transparent window shows raw desktop blur — a
    /// visible flash when clicking a tab that was never displayed.
    private var didShieldFirstPresentation = false

    private func shieldFirstPresentationFlash() {
        guard !didShieldFirstPresentation,
              let terminalWindow = window as? TerminalWindow,
              let container = sidebarSplitView?.arrangedSubviews.last
        else { return }
        didShieldFirstPresentation = true

        let shield = NSView(frame: container.bounds)
        shield.autoresizingMask = [.width, .height]
        shield.wantsLayer = true
        shield.layer?.backgroundColor = terminalWindow.preferredBackgroundColor?.cgColor
        container.addSubview(shield)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                shield.animator().alphaValue = 0
            }, completionHandler: {
                shield.removeFromSuperview()
            })
        }
    }

    private func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // Let our window handle its own appearance
        guard let window = window as? TerminalWindow else { return }

        // Sync our zoom state for splits
        window.surfaceIsZoomed = surfaceTree.zoomed != nil

        // Set the font for the window and tab titles.
        if let titleFontName = surfaceConfig.windowTitleFontFamily {
            window.titlebarFont = NSFont(name: titleFontName, size: NSFont.systemFontSize)
        } else {
            window.titlebarFont = nil
        }

        // Call this last in case it uses any of the properties above.
        window.syncAppearance(surfaceConfig)
        terminalViewContainer?.ghosttyConfigDidChange(ghostty.config, preferredBackgroundColor: window.preferredBackgroundColor)
    }

    /// Adjusts the given frame for the configured window position.
    func adjustForWindowPosition(frame: NSRect, on screen: NSScreen) -> NSRect {
        guard let x = derivedConfig.windowPositionX else { return frame }
        guard let y = derivedConfig.windowPositionY else { return frame }

        // Convert top-left coordinates to bottom-left origin using our utility extension
        let origin = screen.origin(
            fromTopLeftOffsetX: CGFloat(x),
            offsetY: CGFloat(y),
            windowSize: frame.size)

        // Clamp the origin to ensure the window stays fully visible on screen
        var safeOrigin = origin
        let vf = screen.visibleFrame
        safeOrigin.x = min(max(safeOrigin.x, vf.minX), vf.maxX - frame.width)
        safeOrigin.y = min(max(safeOrigin.y, vf.minY), vf.maxY - frame.height)

        // Return our new origin
        var result = frame
        result.origin = safeOrigin
        return result
    }

    /// This is called anytime a node in the surface tree is being removed.
    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // If this isn't the root then we're dealing with a split closure.
        if surfaceTree.root != node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // More than 1 window means we have tabs and we're closing a tab
        if window?.tabGroup?.windows.count ?? 0 > 1 {
            if withConfirmation {
                closeTab(nil)
            } else {
                closeTabImmediately()
            }
            return
        }

        // 1 window, closing the window
        if withConfirmation {
            closeWindow(nil)
        } else {
            closeWindowImmediately()
        }
    }

    func closeTabImmediately(registerRedo: Bool = true) {
        guard let window = window else { return }
        guard let tabGroup = window.tabGroup,
                tabGroup.windows.count > 1 else {
            closeWindowImmediately()
            return
        }

        cancelPendingInitialPresentation()

        // Undo
        if let undoManager, let undoState {
            // Register undo action to restore the tab
            undoManager.setActionName("Close Tab")
            undoManager.registerUndo(
                withTarget: ghostty,
                expiresAfter: undoExpiration
            ) { ghostty in
                let newController = TerminalController(ghostty, with: undoState)

                if registerRedo {
                    undoManager.registerUndo(
                        withTarget: newController,
                        expiresAfter: newController.undoExpiration
                    ) { target in
                        target.closeTabImmediately()
                    }
                }
            }
        }

        window.close()
    }

    private func closeOtherTabsImmediately() {
        guard let window = window else { return }
        guard let tabGroup = window.tabGroup else { return }
        guard tabGroup.windows.count > 1 else { return }

        // Start an undo grouping
        if let undoManager {
            undoManager.beginUndoGrouping()
        }
        defer {
            undoManager?.endUndoGrouping()
        }

        // Iterate through all tabs except the current one.
        for window in tabGroup.windows where window != self.window {
            // We ignore any non-terminal tabs. They don't currently exist and we can't
            // properly undo them anyways so I'd rather ignore them and get a bug report
            // later if and when we introduce non-terminal tabs.
            if let controller = window.windowController as? TerminalController {
                // We must not register a redo, because it messes with our own redo
                // that we register later.
                controller.closeTabImmediately(registerRedo: false)
            }
        }

        if let undoManager {
            undoManager.setActionName("Close Other Tabs")

            // We need to register an undo that refocuses this window. Otherwise, the
            // undo operation above for each tab will steal focus.
            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                DispatchQueue.main.async {
                    target.window?.makeKeyAndOrderFront(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: target,
                    expiresAfter: target.undoExpiration
                ) { target in
                    target.closeOtherTabsImmediately()
                }
            }
        }
    }

    private func closeTabsOnTheRightImmediately() {
        guard let window = window else { return }
        guard let tabGroup = window.tabGroup else { return }
        guard let currentIndex = tabGroup.windows.firstIndex(of: window) else { return }

        let tabsToClose = tabGroup.windows.enumerated().filter { $0.offset > currentIndex }
        guard !tabsToClose.isEmpty else { return }

        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
        }

        for (_, candidate) in tabsToClose {
            if let controller = candidate.windowController as? TerminalController {
                controller.closeTabImmediately(registerRedo: false)
            }
        }

        if let undoManager {
            undoManager.setActionName("Close Tabs to the Right")

            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                DispatchQueue.main.async {
                    target.window?.makeKeyAndOrderFront(nil)
                }

                undoManager.registerUndo(
                    withTarget: target,
                    expiresAfter: target.undoExpiration
                ) { target in
                    target.closeTabsOnTheRightImmediately()
                }
            }
        }
    }

    /// Closes the current window (including any other tabs) immediately and without
    /// confirmation. This will setup proper undo state so the action can be undone.
    func closeWindowImmediately() {
        guard let window = window else { return }

        cancelPendingInitialPresentation()

        registerUndoForCloseWindow()

        if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
            tabGroup.windows.forEach { window in
                // Clear out the surfacetree to ensure there is no undo state.
                // This prevents unnecessary undos registered since AppKit may
                // process them on later ticks so we can't just disable undo registration.
                if let controller = window.windowController as? TerminalController {
                    controller.cancelPendingInitialPresentation()
                    controller.surfaceTree = .init()
                }

                window.close()
            }
        } else {
            window.close()
        }
    }

    /// Registers undo for closing window(s), handling both single windows and tab groups.
    private func registerUndoForCloseWindow() {
        guard let undoManager, undoManager.isUndoRegistrationEnabled else { return }
        guard let window else { return }

        // If we don't have a tab group or we don't have multiple tabs, then
        // do a normal single window close.
        guard let tabGroup = window.tabGroup,
              tabGroup.windows.count > 1 else {
            // No tabs, just save this window's state
            if let undoState {
                // Register undo action to restore the window
                undoManager.setActionName("Close Window")
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: undoExpiration) { ghostty in
                        // Restore the undo state
                        let newController = TerminalController(ghostty, with: undoState)

                        // Register redo action
                        undoManager.registerUndo(
                            withTarget: newController,
                            expiresAfter: newController.undoExpiration) { target in
                                target.closeWindowImmediately()
                            }
                    }
            }

            return
        }

        // Multiple windows in tab group - collect all undo states in sorted order
        // by tab ordering. Also track which window was key.
        let undoStates = tabGroup.windows
            .compactMap { tabWindow -> UndoState? in
                guard let controller = tabWindow.windowController as? TerminalController,
                      var undoState = controller.undoState else { return nil }
                // Clear the tab group reference since it is unneeded. It should be
                // garbage collected but we want to be extra sure we don't try to
                // restore into it because we're going to recreate it.
                undoState.tabGroup = nil
                return undoState
            }
            .sorted { (lhs, rhs) in
                switch (lhs.tabIndex, rhs.tabIndex) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return true
                }
            }

        // Find the index of the key window in our sorted states. This is a bit verbose
        // but we only need this for this style of undo so we don't want to add it to
        // UndoState.
        let keyWindowIndex: Int?
        if let keyWindow = tabGroup.windows.first(where: { $0.isKeyWindow }),
            let keyController = keyWindow.windowController as? TerminalController,
            let keyUndoState = keyController.undoState {
            keyWindowIndex = undoStates.firstIndex {
                $0.tabIndex == keyUndoState.tabIndex }
        } else {
            keyWindowIndex = nil
        }

        // Register undo action to restore all windows
        guard !undoStates.isEmpty else { return }

        undoManager.setActionName("Close Window")
        undoManager.registerUndo(
            withTarget: ghostty,
            expiresAfter: undoExpiration
        ) { ghostty in
            // Restore all windows in the tab group
            let controllers = undoStates.map { undoState in
                TerminalController(ghostty, with: undoState)
            }

            // The first controller becomes the parent window for all tabs.
            // If we don't have a first controller (shouldn't be possible?)
            // then we can't restore tabs.
            guard let firstController = controllers.first else { return }

            // Add all subsequent controllers as tabs to the first window
            for controller in controllers.dropFirst() {
                controller.showWindow(nil)
                if let firstWindow = firstController.window,
                   let newWindow = controller.window {
                    firstWindow.addTabbedWindowSafely(newWindow, ordered: .above)
                }
            }

            // Make the appropriate window key. If we had a key window, restore it.
            // Otherwise, make the last window key.
            if let keyWindowIndex, keyWindowIndex < controllers.count {
                controllers[keyWindowIndex].window?.makeKeyAndOrderFront(nil)
            } else {
                controllers.last?.window?.makeKeyAndOrderFront(nil)
            }

            // Register redo action on the first controller
            undoManager.registerUndo(
                withTarget: firstController,
                expiresAfter: firstController.undoExpiration
            ) { target in
                target.closeWindowImmediately()
            }
        }
    }

    /// Close all windows, asking for confirmation if necessary.
    static func closeAllWindows() {
        // The window we use for confirmations. Try to find the first window that
        // needs quit confirmation. This lets us attach the confirmation to something
        // that is running.
        guard let confirmWindow = all
            .first(where: { $0.surfaceTree.contains(where: { $0.needsConfirmQuit }) })?
            .surfaceTree.first(where: { $0.needsConfirmQuit })?
            .window
        else {
            closeAllWindowsImmediately()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close All Windows?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close All Windows")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: confirmWindow, completionHandler: { response in
            if response == .alertFirstButtonReturn {
                // This is important so that we avoid losing focus when Stage
                // Manager is used (#8336)
                alert.window.orderOut(nil)
                closeAllWindowsImmediately()
            }
        })
    }

    static private func closeAllWindowsImmediately() {
        let undoManager = (NSApp.delegate as? AppDelegate)?.undoManager
        undoManager?.beginUndoGrouping()
        all.forEach { $0.closeWindowImmediately() }
        undoManager?.setActionName("Close All Windows")
        undoManager?.endUndoGrouping()
    }

    // MARK: Undo/Redo

    /// The state that we require to recreate a TerminalController from an undo.
    struct UndoState {
        let frame: NSRect
        let surfaceTree: SplitTree<Ghostty.SurfaceView>
        let focusedSurface: UUID?
        let tabIndex: Int?
        weak var tabGroup: NSWindowTabGroup?
        let tabColor: TerminalTabColor
    }

    convenience init(_ ghostty: Ghostty.App, with undoState: UndoState) {
        self.init(ghostty, withSurfaceTree: undoState.surfaceTree)

        // Show the window and restore its frame
        showWindow(nil)
        if let window {
            window.setFrame(undoState.frame, display: true)
            if let terminalWindow = window as? TerminalWindow {
                terminalWindow.tabColor = undoState.tabColor
            }

            // If we have a tab group and index, restore the tab to its original position
            if let tabGroup = undoState.tabGroup,
               let tabIndex = undoState.tabIndex {
                if tabIndex < tabGroup.windows.count {
                    // Find the window that is currently at that index
                    let currentWindow = tabGroup.windows[tabIndex]
                    currentWindow.addTabbedWindowSafely(window, ordered: .below)
                } else {
                    tabGroup.windows.last?.addTabbedWindowSafely(window, ordered: .above)
                }

                // Make it the key window
                window.makeKeyAndOrderFront(nil)
            }

            // Restore focus to the previously focused surface
            if let focusedUUID = undoState.focusedSurface,
               let focusTarget = surfaceTree.first(where: { $0.id == focusedUUID }) {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: focusTarget, from: nil)
                }
            } else if let focusedSurface = surfaceTree.first {
                // No prior focused surface or we can't find it, let's focus
                // the first.
                self.focusedSurface = focusedSurface
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: focusedSurface, from: nil)
                }
            }
        }
    }

    /// The current undo state for this controller
    var undoState: UndoState? {
        guard let window else { return nil }
        guard !surfaceTree.isEmpty else { return nil }
        return .init(
            frame: window.frame,
            surfaceTree: surfaceTree,
            focusedSurface: focusedSurface?.id,
            tabIndex: window.tabGroup?.windows.firstIndex(of: window),
            tabGroup: window.tabGroup,
            tabColor: (window as? TerminalWindow)?.tabColor ?? .none)
    }

    // MARK: - NSWindowController

    override func windowWillLoad() {
        // We do NOT want to cascade because we handle this manually from the manager.
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window else { return }

        // I copy this because we may change the source in the future but also because
        // I regularly audit our codebase for "ghostty.config" access because generally
        // you shouldn't use it. Its safe in this case because for a new window we should
        // use whatever the latest app-level config is.
        let config = ghostty.config

        // Setting all three of these is required for restoration to work.
        window.isRestorable = restorable
        if restorable {
            window.restorationClass = TerminalWindowRestoration.self
            window.identifier = .init(String(describing: TerminalWindowRestoration.self))
        }

        // If we have only a single surface (no splits) and there is a default size then
        // we should resize to that default size.
        if case let .leaf(view) = surfaceTree.root {
            // If this is our first surface then our focused surface will be nil
            // so we force the focused surface to the leaf.
            focusedSurface = view
        }

        // Initialize our content view to the SwiftUI root
        // Deliberately *not* wrapped in anything.
        //
        // `TerminalViewContainer.intrinsicContentSize` reads the hosting
        // view's, which SwiftUI derives from the ideal size the terminal
        // propagates — and it keeps `initialContentSize` around precisely
        // because that answer is wrong until focus has settled. A wrapper
        // becomes the view whose ideal size is asked for, so the pane's tab
        // bar is a sibling in `rightPane` instead and the terminal is pushed
        // down by an additional safe-area inset. Structural caution, not a
        // fix for an observed failure: the wrapper version was never proven
        // to break anything.
        let container = TerminalViewContainer {
            // The pane's tab bar sits above this, and *above* has to mean
            // above — an overlay put the bar on top of the shell's first
            // lines and stacked its blur over the terminal's, which is the
            // darker band that showed up. The wrapper *observes* the centre:
            // reading the inset inline froze the value this closure was built
            // with (zero), which is why the first version of this fix changed
            // nothing on screen.
            PaneTabBarInsetView(center: self.editorCenter) {
                TerminalView(ghostty: self.ghostty, viewModel: self, delegate: self)
            }
        }

        // Set the initial content size on the container so that
        // intrinsicContentSize returns the correct value immediately,
        // without waiting for @FocusedValue to propagate through the
        // SwiftUI focus chain.
        container.initialContentSize = focusedSurface?.initialSize

        if config.sidebar {
            window.contentView = makeSidebarSplitView(
                terminalContainer: container,
                window: window,
                config: config
            )
        } else {
            window.contentView = container
        }

        // If we have a default size, we want to apply it.
        if let defaultSize {
            defaultSize.apply(to: window)

            if case .contentIntrinsicSize = defaultSize {
                if let screen = window.screen ?? NSScreen.main {
                    let frame = self.adjustForWindowPosition(frame: window.frame, on: screen)
                    window.setFrameOrigin(frame.origin)
                }
            }
        }

        // In various situations, macOS automatically tabs new windows. Ghostty handles
        // its own tabbing so we DONT want this behavior. This detects this scenario and undoes
        // it.
        //
        // Example scenarios where this happens:
        //   - When the system user tabbing preference is "always"
        //   - When the "+" button in the tab bar is clicked
        //
        // We don't run this logic in fullscreen because in fullscreen this will end up
        // removing the window and putting it into its own dedicated fullscreen, which is not
        // the expected or desired behavior of anyone I've found.
        if !window.styleMask.contains(.fullScreen) {
            // If we have more than 1 window in our tab group we know we're a new window.
            // Since Ghostty manages tabbing manually this will never be more than one
            // at this point in the AppKit lifecycle (we add to the group after this).
            if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                window.tabGroup?.removeWindow(window)
            }
        }

        // Apply any additional appearance-related properties to the new window. We
        // apply this based on the root config but change it later based on surface
        // config (see focused surface change callback).
        syncAppearance(.init(config))
    }

    /// Builds the sidebar | terminal split view used as the window content
    /// view when the sidebar is enabled. Native tabbing stays untouched;
    /// the sidebar is purely an alternative presentation of the tab group.
    private func makeSidebarSplitView(
        terminalContainer: NSView,
        window: NSWindow,
        config: Ghostty.Config
    ) -> NSView {
        (window as? TerminalWindow)?.sidebarActive = true

        // The sidebar pane runs the full height of the window so its glass
        // layer reaches the titlebar strip. The strip's own color comes from
        // the titlebar, not the panes — see the hosting view's top anchor.
        window.styleMask.insert(.fullSizeContentView)

        let tabManager = SidebarTabManager(window: window)
        self.sidebarTabManager = tabManager

        let layout = SidebarLayoutModel()
        layout.onNewTab = { [weak self] in
            self?.newSidebarTab(in: nil)
        }
        layout.onNewClaudeTab = { [weak self] in
            self?.newSidebarTab(in: nil, runningClaude: true)
        }
        layout.onNewCodexTab = { [weak self] in
            self?.newSidebarTab(in: nil, runningCodex: true)
        }
        layout.onNewOpenCodeTab = { [weak self] in
            self?.newSidebarTab(in: nil, runningOpenCode: true)
        }
        layout.onNewWorktreeTab = { [weak self] directory in
            self?.newSidebarTab(in: nil, workingDirectory: directory)
        }
        layout.onNewWorktreeTabInGroup = { [weak self] group, directory in
            self?.newSidebarTab(in: group, workingDirectory: directory)
        }
        layout.onNewWorktreeAgentTab = { [weak self] directory, agent in
            self?.newSidebarTab(
                in: nil,
                runningClaude: agent == .claude,
                runningCodex: agent == .codex,
                runningOpenCode: agent == .opencode,
                workingDirectory: directory)
        }
        self.sidebarLayout = layout

        let sidebarHosting = NSHostingView(rootView: SidebarView(
            tabManager: tabManager,
            store: .shared,
            layout: layout,
            editorCenter: editorCenter,
            onNewTabInGroup: { [weak self] group in
                self?.newSidebarTab(in: group)
            },
            onNewClaudeTabInGroup: { [weak self] group in
                self?.newSidebarTab(in: group, runningClaude: true)
            },
            onNewCodexTabInGroup: { [weak self] group in
                self?.newSidebarTab(in: group, runningCodex: true)
            },
            onNewOpenCodeTabInGroup: { [weak self] group in
                self?.newSidebarTab(in: group, runningOpenCode: true)
            },
            onSpawnTerminalBesideSelection: { [weak self] in
                self?.newSidebarTabBesideSelection()
            },
            onOpenInEditor: { [weak self] url in
                self?.openInEditor(url)
            },
            onOpenDiff: { [weak self] url in
                self?.openInEditor(url, showing: .diff)
            },
            onOpenBranchDiff: { [weak self] url, base in
                self?.openBranchDiff(url, base: base)
            }
        ).interfaceFont())
        sidebarHosting.translatesAutoresizingMaskIntoConstraints = false
        sidebarHosting.wantsLayer = true
        self.sidebarBackgroundView = sidebarHosting

        // The pane wraps the hosting view so a glass layer can slot in
        // underneath when the glass effect is active.
        let sidebarPane = NSView()
        sidebarPane.translatesAutoresizingMaskIntoConstraints = false
        sidebarPane.addSubview(sidebarHosting)
        NSLayoutConstraint.activate([
            sidebarHosting.topAnchor.constraint(equalTo: sidebarPane.topAnchor),
            sidebarHosting.leadingAnchor.constraint(equalTo: sidebarPane.leadingAnchor),
            sidebarHosting.bottomAnchor.constraint(equalTo: sidebarPane.bottomAnchor),
            sidebarHosting.trailingAnchor.constraint(equalTo: sidebarPane.trailingAnchor),
        ])
        self.sidebarPane = sidebarPane

        let expanded = [
            /// Below this a group row is an icon and a truncation, which is
            /// not a sidebar. The name now outranks the chrome beside it —
            /// see `SidebarView.header` — so this is a floor on *legibility*
            /// rather than the thing preventing collapse.
            sidebarPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            sidebarPane.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ]
        NSLayoutConstraint.activate(expanded)
        self.sidebarExpandedConstraints = expanded
        self.sidebarCollapsedConstraint =
            sidebarPane.widthAnchor.constraint(equalToConstant: 0)

        // Pin the exact shared width for the first layout pass so new
        // tabs appear at the right size instead of snapping a frame
        // later, then release it so the divider stays draggable.
        if !SidebarCollapseState.shared.isCollapsed {
            let initialWidth = sidebarPane.widthAnchor.constraint(
                equalToConstant: sharedSidebarWidth
            )
            initialWidth.isActive = true
            DispatchQueue.main.async { initialWidth.isActive = false }
        }

        let chromeHosting = NSHostingView(rootView: SidebarTitlebarChrome(
            store: .shared,
            layout: layout,
            tabManager: tabManager,
            editorCenter: editorCenter
        ).interfaceFont())
        chromeHosting.translatesAutoresizingMaskIntoConstraints = false
        self.sidebarChromeView = chromeHosting

        DispatchQueue.main.async { [weak self] in
            self?.attachSidebarChrome()
            self?.syncSidebarBackground()
        }

        sidebarLayoutCancellable = SidebarCollapseState.shared.$isCollapsed
            .removeDuplicates()
            .sink { [weak self] collapsed in
                guard let self else { return }
                if collapsed {
                    NSLayoutConstraint.deactivate(self.sidebarExpandedConstraints)
                    self.sidebarCollapsedConstraint?.isActive = true
                } else {
                    self.sidebarCollapsedConstraint?.isActive = false
                    NSLayoutConstraint.activate(self.sidebarExpandedConstraints)
                    DispatchQueue.main.async { [weak self] in
                        self?.applySharedSidebarWidth()
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.syncSidebarChromeWidth()
                }
            }

        // The sidebar's hosting view paints the titlebar strip on its half
        // because its layer runs the full height of the pane. The terminal's
        // content stops below the titlebar and paints nothing up there, so
        // this fills exactly that band — one coat on each half, and nothing
        // at all under glass, where the material shows through instead.
        // The right side holds the terminal and the editor stacked, and
        // shows one of them. Hiding rather than replacing is deliberate:
        // the shell and its scrollback have to survive opening a file and
        // closing it again, so the terminal view is never torn down.
        let rightPane = NSView()
        rightPane.translatesAutoresizingMaskIntoConstraints = false

        // The terminal joins first, before anything constrains itself to
        // it. Activating a constraint between two views with no common
        // ancestor raises, and raising here leaves the app running with no
        // window at all — it appears in the Dock and never shows itself.
        rightPane.addSubview(terminalContainer)
        self.terminalPaneView = terminalContainer

        let titlebarFiller = NSView()
        titlebarFiller.translatesAutoresizingMaskIntoConstraints = false
        titlebarFiller.wantsLayer = true
        // A sibling of the terminal rather than its child. As a child it
        // disappeared the moment the terminal was hidden for the editor,
        // and the titlebar band went back to showing the bare window —
        // the strip is the *window's*, not the terminal's, and has to be
        // painted whichever half is on screen.
        rightPane.addSubview(titlebarFiller, positioned: .below, relativeTo: nil)
        // Meets the terminal's content exactly. It cannot do better than
        // that: overlapping paints that row twice and reads as a dark
        // line, and falling short leaves the window showing through as a
        // light one. Two translucent surfaces can't tile seamlessly —
        // fixing this properly means one backdrop for the whole window
        // with the terminal drawing no background of its own.
        //
        // The offset carries the part of the strip the window has stopped
        // reserving, which is nothing at all until native fullscreen — where
        // the terminal's safe area goes to zero while its scroll view still
        // insets its content under the detached titlebar, so this is the only
        // thing left to paint that band.
        let fillerBottom = titlebarFiller.bottomAnchor.constraint(
            equalTo: terminalContainer.safeAreaLayoutGuide.topAnchor
        )
        NSLayoutConstraint.activate([
            titlebarFiller.topAnchor.constraint(equalTo: rightPane.topAnchor),
            titlebarFiller.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            titlebarFiller.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            fillerBottom,
        ])
        self.terminalTitlebarFiller = titlebarFiller
        self.terminalTitlebarFillerBottom = fillerBottom

        // The pane's tab bar, above whichever surface is showing. Added after
        // the terminal so that constraining to it is legal: a constraint
        // between views with no common ancestor raises, and raising here
        // leaves the app running with no window at all.
        let tabBarHosting = NSHostingView(
            rootView: EditorPaneTabBar(
                center: editorCenter,
                terminalDirectory: editorTerminalDirectory
            ).interfaceFont()
        )
        tabBarHosting.translatesAutoresizingMaskIntoConstraints = false
        // Layer-backed and coloured by `syncSidebarBackground`, exactly like
        // the editor beside it. Without this the bar had no background at all:
        // the tab labels floated over whatever was behind, and text scrolling
        // under it passed straight through the gap where the terminal's own
        // tab draws nothing.
        tabBarHosting.wantsLayer = true
        // Belt and braces with the `maxWidth: .infinity` on its content: the
        // bar follows the pane's width and never argues about it, whatever
        // SwiftUI decides its ideal size is.
        tabBarHosting.setContentHuggingPriority(.init(1), for: .horizontal)
        tabBarHosting.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        rightPane.addSubview(tabBarHosting)
        let tabBarHeight = tabBarHosting.heightAnchor.constraint(equalToConstant: 0)
        // Offset by the same strip the filler carries, so the bar sits under
        // the titlebar rather than behind it in fullscreen. The terminal's
        // own content lines up with it either way: its SwiftUI inset is the
        // bar's height, applied on top of whatever the window or its scroll
        // view has already pushed the content down by.
        let tabBarTop = tabBarHosting.topAnchor.constraint(
            equalTo: terminalContainer.safeAreaLayoutGuide.topAnchor
        )
        NSLayoutConstraint.activate([
            tabBarTop,
            tabBarHosting.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            tabBarHosting.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            tabBarHeight,
        ])
        self.paneTabBarHeight = tabBarHeight
        self.paneTabBarTopConstraint = tabBarTop
        self.paneTabBarView = tabBarHosting

        let editorHosting = NSHostingView(
            rootView: EditorPaneView(
                center: editorCenter,
                terminalDirectory: editorTerminalDirectory,
                search: workspaceSearch
            ).interfaceFont()
        )
        editorHosting.translatesAutoresizingMaskIntoConstraints = false
        editorHosting.isHidden = true
        // Layer-backed and coloured by `syncSidebarBackground`, exactly like
        // the sidebar pane: the SwiftUI content above it draws nothing of
        // its own, so the window's opacity and blur reach the editor the
        // same way they reach everything else. Painting an opaque colour in
        // SwiftUI instead — which is what this did first — left a solid
        // slab in the middle of a translucent window.
        editorHosting.wantsLayer = true
        rightPane.addSubview(editorHosting)
        self.editorHostingView = editorHosting

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminalContainer.topAnchor.constraint(equalTo: rightPane.topAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            // The terminal container's guide, not the pane's: this view was
            // inserted between the split view and the terminal, and a plain
            // `NSView` in that position reports no safe area of its own, so
            // the editor started at the window's very top and its text
            // scrolled up into the titlebar.
            editorHosting.topAnchor.constraint(equalTo: tabBarHosting.bottomAnchor),
            editorHosting.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            editorHosting.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
            editorHosting.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
        ])

        // Both views are toggled, not just the editor. The editor draws no
        // background of its own — that is what lets the window's blur reach
        // it — so a terminal left visible underneath shows *through* the
        // code, and the shell's last output reads as garbage mixed into the
        // file. Hidden, never removed: the shell and its scrollback have to
        // survive being covered.
        editorCancellable = editorCenter.$tabs
            .removeDuplicates()
            .sink { [weak self] tabs in
                guard let self else { return }
                self.editorHostingView?.isHidden = tabs.showsTerminal
                self.terminalPaneView?.isHidden = !tabs.showsTerminal

                // The bar takes its height only when there is something to
                // switch to, and the terminal is pushed down by exactly that
                // much. An `additionalSafeAreaInsets` rather than a moved top
                // constraint: the terminal's top is what makes the titlebar
                // strip meet its content, and the shell's SwiftUI content
                // already honours the safe area.
                let height: CGFloat = tabs.showsTabBar ? Self.paneTabBarHeightWhenShown : 0
                self.paneTabBarHeight?.constant = height
                // Published, so the terminal's SwiftUI content moves down by
                // exactly the bar's height. `additionalSafeAreaInsets` was
                // tried first and did nothing: the terminal fills its bounds
                // and never consults the safe area.
                self.editorCenter.paneTabBarInset = height
            }

        // The terminal's own tab is labelled with the window's title, which
        // the shell rewrites as it goes. KVO rather than a one-time read, so
        // the tab doesn't sit there naming a directory you left.
        terminalTitleCancellable = window.publisher(for: \.title)
            .map { title in title.isEmpty ? "Terminal" : title }
            .removeDuplicates()
            .sink { [weak self] title in
                self?.editorCenter.terminalTitle = title
            }

        let splitView = SidebarSplitView()
        splitView.editorCenter = editorCenter
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(sidebarPane)
        splitView.addArrangedSubview(rightPane)
        splitView.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        splitView.delegate = self

        self.sidebarSplitView = splitView
        self.sidebarDefaultWidth = config.sidebarWidth

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sidebarWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sidebarTintDidChangeNotification(_:)),
            name: Self.sidebarTintDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(guiConfigDidApplyNotification(_:)),
            name: GuiConfigStore.didApply,
            object: nil
        )
        // The window's own notifications rather than the fullscreen style's
        // delegate: native fullscreen can be entered from the green button
        // or from a restored window, and this has to hold whichever way the
        // window got there.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sidebarFullscreenDidChange(_:)),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sidebarFullscreenDidChange(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )

        DispatchQueue.main.async { [weak self] in
            self?.applySharedSidebarWidth()
        }

        return splitView
    }

    /// Creates a terminal tab that starts inside the given group.
    ///
    /// Working directory rule: project groups start at the project root;
    /// manual groups start at the pwd of the tab selected *inside the
    /// group*, falling back to the group's first terminal; the ungrouped
    /// section starts at the configured default home (`~/` unless changed
    /// in Behaviors). The new surface is pinned to the group it was created
    /// in — including to *no* group — so later `cd`s never move it in or
    /// out.
    @discardableResult
    private func newSidebarTab(
        in group: SidebarGroup?,
        runningClaude: Bool = false,
        runningCodex: Bool = false,
        runningOpenCode: Bool = false,
        inheritingPane: Bool = false,
        workingDirectory: String? = nil
    ) -> Ghostty.SurfaceView? {
        guard let window else { return nil }

        var baseConfig = Ghostty.SurfaceConfiguration()

        /// An explicit directory wins over every group rule: the caller that
        /// passes one — the worktree panel — is naming the whole point of
        /// the tab, and a project group's root silently overriding it would
        /// open the terminal outside the worktree it says it is in.
        baseConfig.workingDirectory = workingDirectory ?? sidebarNewTabDirectory(in: group)

        guard let controller = Self.newTab(ghostty, from: window, withBaseConfig: baseConfig)
        else { return nil }

        let surface = controller.focusedSurface
            ?? controller.surfaceTree.root?.leftmostLeaf()

        // A window normally starts on the terminal list — panels are
        // somewhere you go on purpose, and a remembered one made the
        // explorer seem to follow you between tabs. A terminal opened *by*
        // a panel is the exception: it was created without being asked
        // for, so throwing the user out of the panel they were working in
        // is the surprise, not the continuity.
        if inheritingPane, let pane = sidebarLayout?.selectedPane {
            controller.sidebarLayout?.selectedPane = pane
        }

        // Recorded before the agent is even typed, because *we* know which
        // one it is and the hook might never say. A tab whose hook is not
        // installed used to leave no trace of having run an agent, so a
        // restore had nothing to resume from — see `recordAgentStart`.
        if let surface, let agent = startingAgent(
            claude: runningClaude,
            codex: runningCodex,
            openCode: runningOpenCode
        ) {
            TabStateCenter.shared.recordAgentStart(surfaceId: surface.id, agent: agent)
            ClaudeSession.run(agent.launchCommand, in: surface)
        }

        guard let surface else { return nil }

        // Record the group the tab was *created in*, including when that is
        // no group at all. Leaving the ungrouped case unrecorded is not
        // neutral: `resolveGroup` then falls through to its pwd claim, and
        // any project group whose root contains this terminal's directory
        // adopts it. Opening a terminal outside every group and watching it
        // jump into one is the bug that behavior produces.
        SidebarGroupStore.shared.assign(surfaceId: surface.id, to: group?.id)
        sidebarTabManager?.scheduleRefresh()
        controller.sidebarTabManager?.scheduleRefresh()
        return surface
    }

    /// Which agent a new-tab request is asking for, if any.
    ///
    /// Three booleans arrive from three separate sidebar buttons; this is
    /// where they become the one thing the rest of the flow needs, so that
    /// recording the agent and launching it cannot disagree about which it
    /// was.
    private func startingAgent(
        claude: Bool,
        codex: Bool,
        openCode: Bool
    ) -> CodingAgent? {
        if claude { return .claude }
        if codex { return .codex }
        if openCode { return .opencode }
        return nil
    }

    /// Resolves the working directory for a new sidebar terminal, per the
    /// sidebar rule:
    ///  - project groups open at the project root;
    ///  - manual groups open at the pwd of the tab selected inside the
    ///    group, else the group's first terminal;
    ///  - the ungrouped section opens at the configured default home.
    private func sidebarNewTabDirectory(in group: SidebarGroup?) -> String {
        switch group?.kind {
        case .project(let root):
            return (root as NSString).expandingTildeInPath

        case .manual, .none:
            if let group {
                let members = sidebarTabManager?.models.filter { model in
                    SidebarGroupStore.shared.resolveGroup(
                        surfaceId: model.surfaceId,
                        pwd: model.pwd
                    )?.id == group.id
                } ?? []
                if let selected = members.first(where: { $0.isSelected }),
                   let pwd = selected.pwd, !pwd.isEmpty {
                    return pwd
                }
                if let first = members.first, let pwd = first.pwd, !pwd.isEmpty {
                    return pwd
                }
            }
            return Self.sidebarDefaultHomeDirectory
        }
    }

    /// The home directory new sidebar terminals start in when no group
    /// rule applies. Defaults to the user's home; overridable in Behaviors.
    static var sidebarDefaultHomeDirectory: String {
        let configured = UserDefaults.standard.string(forKey: "SidebarNewTabHomeDirectory") ?? ""
        let expanded = (configured as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return expanded
    }

    /// Opens a file in this window's editor, explaining it when the editor
    /// can't.
    ///
    /// The explanation has to happen here rather than inside the pane: the
    /// pane is hidden whenever nothing is open, so a refusal shown there
    /// would be shown *nowhere*. Clicking a `.class` file did exactly that
    /// — nothing at all happened, which reads as the app being broken
    /// rather than as an answer.
    /// The directory a relative path from terminal output is relative to.
    ///
    /// The focused surface's own working directory, which is the only thing a
    /// relative path in its output could have meant.
    var workingDirectoryForPaths: String? {
        if let pwd = focusedSurface?.pwd, !pwd.isEmpty { return pwd }
        return sidebarTabManager?.models.first { $0.isSelected }?.pwd
    }

    /// Opens a path clicked in the terminal, honouring the Settings choice.
    ///
    /// Routed through the same opener the panels use, so "where do files
    /// open" has one answer in the whole app rather than one per entry point.
    func openClickedPath(_ url: URL, line: Int?, column: Int?) {
        guard FileOpenAction.current != .builtInEditor else {
            openInEditor(url, line: line, column: column)
            return
        }

        FileOpener.prompt(
            for: url,
            in: window,
            currentTerminal: focusedSurface,
            spawnTerminal: { [weak self] in self?.newSidebarTabBesideSelection() },
            openInEditor: { [weak self] target in
                self?.openInEditor(target, line: line, column: column)
            }
        )
    }

    /// Opens a file in this window's editor.
    ///
    /// Exposed for the app delegate, which receives files from outside — the
    /// Finder, a Dock drop, `open -a` — and has no editor of its own to hand
    /// them to.
    func openFileInEditor(_ url: URL) {
        openInEditor(url)
    }

    /// Opens a file as the branch review sees it: its diff against the base
    /// the review was measured from, rather than against the working tree.
    func openBranchDiff(_ url: URL, base: String) {
        openInEditor(url, showing: .diff, reviewBase: base)
    }

    private func openInEditor(
        _ url: URL,
        line: Int? = nil,
        column: Int? = nil,
        showing: EditorPresentation? = nil,
        reviewBase: String? = nil
    ) {
        // A line from a compiler or a stack trace is one-based; the editor's
        // reveal is zero-based, like the protocol it came from.
        let reveal = line.map { line in
            let position = LSPPosition(
                line: max(0, line - 1),
                character: max(0, (column ?? 1) - 1)
            )
            return LSPRange(start: position, end: position)
        }

        guard !editorCenter.open(
            url,
            reveal: reveal,
            showing: showing,
            reviewBase: reviewBase
        ) else { return }
        openInEditorFailed(url)
    }

    private func openInEditorFailed(_ url: URL) {
        guard let failure = editorCenter.openFailure, let window else { return }
        editorCenter.openFailure = nil

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = url.lastPathComponent
        alert.informativeText = failure.verdict.reason ?? "This file can't be opened here."
        alert.addButton(withTitle: "Open in Another App")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            FileOpener.openInApp(url, window: window)
        }
    }

    /// Opens a terminal directly below the selected one, in whatever group
    /// that one lives in — including no group at all.
    ///
    /// This is what the panels use to open a file. They list the contents
    /// of the *selected* terminal, so a file they open belongs beside that
    /// terminal; dropping it at the end of the list would separate it from
    /// the context it came from.
    private func newSidebarTabBesideSelection() -> Ghostty.SurfaceView? {
        let selected = sidebarTabManager?.models.first { $0.isSelected }
        let group = SidebarGroupStore.shared.resolveGroup(
            surfaceId: selected?.surfaceId,
            pwd: selected?.pwd
        )

        guard let surface = newSidebarTab(in: group, inheritingPane: true)
        else { return nil }

        // `newSidebarTab` only assigns a group; the position within it is
        // this method's whole point, so it is set here — and only when
        // there is a neighbour to anchor to.
        if let anchor = selected?.surfaceId {
            SidebarGroupStore.shared.insert(
                surfaceId: surface.id,
                near: anchor,
                after: true,
                groupId: group?.id
            )
            sidebarTabManager?.scheduleRefresh()
        }
        return surface
    }

    /// The app-wide sidebar width: last width the user dragged to in any
    /// window, falling back to the config value.
    private var sharedSidebarWidth: CGFloat {
        let saved = UserDefaults.standard.double(forKey: Self.sidebarWidthDefaultsKey)
        return saved > 0 ? CGFloat(saved) : sidebarDefaultWidth
    }

    /// Applied when this window becomes key so a drag done in another tab
    /// carries over to this one.
    @objc private func sidebarWindowDidBecomeKey(_ notification: Notification) {
        applySharedSidebarWidth()
        shieldFirstPresentationFlash()
    }

    @objc private func sidebarTintDidChangeNotification(_ notification: Notification) {
        syncSidebarBackground()
        // An immediate, synchronous redraw — not just a dirty flag for
        // the next display cycle — so divider style/color changes in
        // Settings reflect right away instead of needing a reopen.
        sidebarSplitView?.display()
    }

    /// Settings applies hot-reload the config; the surface state that
    /// feeds window and sidebar treatments lands a beat later, so the
    /// full appearance sync runs twice — immediately and after the
    /// reload settles. The second pass also re-asserts glass, which the
    /// window server occasionally drops during background churn.
    @objc private func guiConfigDidApplyNotification(_ notification: Notification) {
        syncAppearance()
        syncSidebarBackground()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.syncAppearance()
            self?.syncSidebarBackground()
            self?.sidebarSplitView?.needsDisplay = true
        }
    }

    private func applySharedSidebarWidth() {
        guard let splitView = sidebarSplitView,
              let sidebar = splitView.arrangedSubviews.first
        else { return }
        defer { syncSidebarChromeWidth() }
        let target = sharedSidebarWidth
        guard abs(sidebar.frame.width - target) > 0.5 else { return }
        splitView.setPosition(target, ofDividerAt: 0)
    }

    /// Adds the chrome into the titlebar container, vertically centered
    /// on the traffic lights. Safe to call repeatedly: re-attaches after
    /// titlebar rebuilds (theme changes, appearance syncs).
    private func attachSidebarChrome() {
        guard let chrome = sidebarChromeView,
              let closeButton = window?.standardWindowButton(.closeButton),
              let titlebar = closeButton.superview
        else { return }
        guard chrome.superview != titlebar else {
            syncSidebarChromeWidth()
            return
        }

        chrome.removeFromSuperview()
        titlebar.addSubview(chrome)

        let trailing = chrome.trailingAnchor.constraint(
            equalTo: titlebar.leadingAnchor,
            constant: sharedSidebarWidth - 8
        )
        NSLayoutConstraint.activate([
            trailing,
            chrome.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
        ])
        sidebarChromeTrailingConstraint = trailing

        syncSidebarChromeWidth()
    }

    /// Keeps the chrome's trailing edge at the sidebar's right edge
    /// (or parked next to the traffic lights when collapsed).
    private func syncSidebarChromeWidth() {
        // The strip the icons live in is the same strip the panes have to
        // stay out of, so both are resolved together and every caller of
        // this — collapse, divider drag, appearance sync, config reload, the
        // fullscreen transition — keeps them in agreement.
        syncTitlebarStripInsets()

        guard let chrome = sidebarChromeView else { return }

        if chrome.superview == nil {
            attachSidebarChrome()
            return
        }

        guard let constraint = sidebarChromeTrailingConstraint, let window else { return }

        let trafficLightsInset = window.standardWindowButton(.zoomButton)
            .map { $0.frame.maxX + 6 } ?? 78

        if SidebarCollapseState.shared.isCollapsed {
            constraint.constant = trafficLightsInset + 32
        } else {
            let sidebarWidth = sidebarSplitView?.arrangedSubviews.first?.frame.width
                ?? sharedSidebarWidth
            constraint.constant = max(trafficLightsInset + 32, sidebarWidth - 8)
        }

        // Keep the centered title out of the chrome it would otherwise
        // overlap: the icons end where this constraint puts them.
        (window as? TerminalWindow)?.titlebarLeadingInset = constraint.constant + 12
    }

    /// Hands both panes whatever part of the titlebar strip the window has
    /// stopped reserving, so the sidebar's first row, the terminal's filler
    /// and the pane tab bar all sit against the strip in native fullscreen
    /// the way they do in an ordinary window.
    ///
    /// The terminal pane is the yardstick for what *is* reserved because it
    /// is the view AppKit hands the strip to — the filler has always been
    /// measured off exactly this inset (see `makeSidebarSplitView`), and it
    /// reads zero in fullscreen, which is the shortfall put back here.
    ///
    /// No mode check, because none is needed: `NSTitlebarView` lives inside
    /// the titlebar container, and the container is what the window stops its
    /// content below. The measured strip can therefore never exceed what the
    /// window reserves outside of fullscreen, so the arithmetic yields zero
    /// there on its own and windowed layout is left exactly as it was.
    private func syncTitlebarStripInsets() {
        guard let window else { return }

        let shortfall = SidebarLayoutModel.titlebarShortfall(
            titlebarHeight: visibleTitlebarHeight(of: window),
            reservedByWindow: terminalPaneView?.safeAreaInsets.top ?? 0
        )

        // The filler's bottom and the tab bar's top hang off the terminal's
        // safe area, so both take the shortfall as their offset: nothing
        // moves at zero, and in fullscreen both land on the strip's edge.
        terminalTitlebarFillerBottom?.constant = shortfall
        paneTabBarTopConstraint?.constant = shortfall

        // Assigned only on a real change: this runs on every divider drag
        // and every appearance sync, and a `@Published` write invalidates
        // the whole sidebar body whether the value moved or not.
        guard let layout = sidebarLayout,
              abs(layout.titlebarInset - shortfall) > 0.5
        else { return }
        layout.titlebarInset = shortfall
    }

    /// The height of the titlebar strip this window actually shows, zero
    /// when it shows none.
    ///
    /// The hidden-titlebar style keeps the traffic lights and their
    /// container around and hides them, and non-native fullscreen drops
    /// `.titled` altogether so there are no buttons to ask. Neither has a
    /// strip for the sidebar to stay clear of.
    private func visibleTitlebarHeight(of window: NSWindow) -> CGFloat {
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview,
              !titlebar.isHiddenOrHasHiddenAncestor
        else { return 0 }
        return titlebar.frame.height
    }

    /// Re-resolves the titlebar strip across a fullscreen transition.
    ///
    /// Entering native fullscreen moves the titlebar into its own window,
    /// which both changes the strip the panes must reserve and can hand the
    /// chrome a new titlebar view to live in. Both helpers are idempotent, so
    /// exiting runs the same path back.
    @objc private func sidebarFullscreenDidChange(_ notification: Notification) {
        attachSidebarChrome()
        syncTitlebarStripInsets()

        // Again on the next turn: the fullscreen titlebar is not always laid
        // out by the time the notification lands, and an unmeasured strip
        // reads as no strip at all.
        DispatchQueue.main.async { [weak self] in
            self?.attachSidebarChrome()
            self?.syncTitlebarStripInsets()
        }
    }

    // MARK: NSSplitViewDelegate

    /// Keeps the sidebar resizable when the divider is hidden.
    ///
    /// AppKit derives the drag area from `dividerThickness`, which is zero in
    /// that mode so the panes can meet with nothing between them to paint.
    /// This hands back a grabbable band over the seam.
    func splitView(
        _ splitView: NSSplitView,
        additionalEffectiveRectOfDividerAt dividerIndex: Int
    ) -> NSRect {
        guard splitView.dividerThickness == 0,
              let sidebar = splitView.arrangedSubviews.first
        else { return .zero }

        let grabWidth: CGFloat = 6
        return NSRect(
            x: sidebar.frame.maxX - grabWidth / 2,
            y: splitView.bounds.minY,
            width: grabWidth,
            height: splitView.bounds.height
        )
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        syncSidebarChromeWidth()

        guard let splitView = sidebarSplitView,
              window?.isKeyWindow == true,
              let width = splitView.arrangedSubviews.first?.frame.width,
              width > 0
        else { return }
        UserDefaults.standard.set(Double(width), forKey: Self.sidebarWidthDefaultsKey)
    }

    /// Setup correct window frame before showing the window
    override func showWindow(_ sender: Any?) {
        guard let terminalWindow = window as? TerminalWindow else { return }

        // Set the initial window position. This must happen after the window
        // is fully set up (content view, toolbar, default size) so that
        // decorations added by subclass awakeFromNib (e.g. toolbar for tabs
        // style) don't change the frame after the position is restored.
        let originChanged = terminalWindow.setInitialWindowPosition(
            x: derivedConfig.windowPositionX,
            y: derivedConfig.windowPositionY,
        )
        let restored = LastWindowPosition.shared.restore(
            terminalWindow,
            origin: !originChanged,
            size: defaultSize == nil,
        )

        // A window this app opens is centred and wide enough to hold the
        // sidebar, rather than inheriting wherever and whatever the last one
        // was. See `initialFrame` for what "wide enough" is measured against.
        //
        // Deliberately ahead of `LastWindowPosition`, whose whole job is to
        // reopen where you left off: that is the right default for a plain
        // terminal and the wrong one here, because the size it restores is
        // whatever the previous window happened to be dragged to, and a
        // window narrowed once stays narrow for every window after it.
        //
        // Three things still win, in this order: an explicit
        // `window-position-x/y`, an explicit `window-width/height` or
        // `maximize` — both of which arrive as `defaultSize` — and being a
        // tab, where setting a frame would move the whole group rather than
        // this window. That last guard is the same test the cascade above
        // uses, and for the same reason.
        let isAloneInItsGroup = (terminalWindow.tabGroup?.windows.count ?? 1) == 1
        if !originChanged, defaultSize == nil, isAloneInItsGroup,
           !terminalWindow.styleMask.contains(.fullScreen),
           let screen = terminalWindow.screen ?? NSScreen.main {
            terminalWindow.setFrame(
                Self.initialFrame(sidebarWidth: sharedSidebarWidth, visible: screen.visibleFrame),
                display: true
            )
        } else if !originChanged, !restored {
            // This doesn't work in `windowDidLoad` somehow
            terminalWindow.center()
        }

        super.showWindow(sender)

        syncAppearance()
    }

    // Shows the "+" button in the tab bar, responds to that click.
    override func newWindowForTab(_ sender: Any?) {
        // Trigger the ghostty core event logic for a new tab.
        guard let surface = self.focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    // MARK: NSWindowDelegate

    // TabGroupCloseCoordinator.Controller
    lazy private(set) var tabGroupCloseCoordinator = TabGroupCloseCoordinator()

    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        tabGroupCloseCoordinator.windowShouldClose(sender) { [weak self] scope in
            guard let self else { return }
            switch scope {
            case .tab: closeTab(nil)
            case .window:
                guard self.window?.isFirstWindowInTabGroup ?? false else { return }
                closeWindow(nil)
            }
        }

        // We will always explicitly close the window using the above
        return false
    }

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)

        // A closed window leaves the session store too.
        PhantomSessionStore.shared.scheduleSave()

        cancelPendingInitialPresentation()
        self.relabelTabs()
        releaseSidebarChrome()

        // If we remove a window, we reset the cascade point to the key window so that
        // the next window cascade's from that one.
        if let focusedWindow = NSApplication.shared.keyWindow {
            // If we are NOT the focused window, then we are a tabbed window. If we
            // are closing a tabbed window, we want to set the cascade point to be
            // the next cascade point from this window.
            if focusedWindow != window {
                // The cascadeTopLeft call below should NOT move the window. Starting with
                // macOS 15, we found that specifically when used with the new window snapping
                // features of macOS 15, this WOULD move the frame. So we keep track of the
                // old frame and restore it if necessary. Issue:
                // https://github.com/ghostty-org/ghostty/issues/2565
                let oldFrame = focusedWindow.frame

                Self.lastCascadePoint = focusedWindow.cascadeTopLeft(from: .zero)

                if focusedWindow.frame != oldFrame {
                    focusedWindow.setFrame(oldFrame, display: true)
                }

                return
            }

            // If we are the focused window, then we set the last cascade point to
            // our own frame so that it shows up in the same spot.
            let frame = focusedWindow.frame
            Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }

    /// Drops every strong reference the sidebar layout keeps on this window's
    /// view tree, so closing the window can actually deallocate it.
    ///
    /// `BaseTerminalController.windowWillClose` clears `contentView`, and for a
    /// window whose only strong link to its content is that one property that
    /// is enough: the content view goes, and with it the terminal's hosting
    /// view, whose root view holds `TerminalView(viewModel: self)` — the edge
    /// that would otherwise point back at this controller.
    ///
    /// The sidebar path builds a second set of links that `contentView = nil`
    /// cannot reach: the split view itself, the chrome views, and the editor's
    /// hosting view. Any one of them keeps the right pane alive, the right pane
    /// keeps the terminal's hosting view alive, and the cycle back through the
    /// controller closes again.
    ///
    /// The constraints are cleared too, and they are **not** part of that —
    /// `NSLayoutConstraint` refers to its items weakly, so holding one holds no
    /// view. This was written believing otherwise; the test that was supposed
    /// to pin the belief refuted it instead, and now pins the refutation. They
    /// are dropped as tidiness, so nothing here reads as load-bearing when it
    /// is not.
    ///
    /// The cost of leaving it closed is not just memory: a controller that
    /// never deallocates never releases its surface tree, a surface owns its
    /// pty, and a pty that is never closed sends nobody `SIGHUP` — so the
    /// shell and everything the reader started in it go on running after the
    /// tab has left the screen. That is the shape of the report this came
    /// from: `agy` and `opencode` still in Activity Monitor after their tabs
    /// were closed.
    ///
    /// The chain is read from the code rather than from a profiler, and the
    /// links are checkable: every property below is a strong reference, an
    /// activated constraint retains the view it was installed in, and
    /// `BaseTerminalController.windowWillClose` clears `contentView` and
    /// nothing else. A window opened without the sidebar has only that one
    /// link, which is why upstream tears down correctly and this path does
    /// not.
    ///
    /// Only `sidebarSplitView` was measured holding the detached tree — it was
    /// the one direct owner of the tree's root in a leaked window. The rest of
    /// this list is deliberately defensive: each is a strong reference into the
    /// same tree that would keep it alive on its own, and the failure they
    /// cause is invisible until someone reads `ps`. That costs a line here per
    /// reference the sidebar path adds, which is the trade this accepts — if
    /// you add one, add it here too.
    private func releaseSidebarChrome() {
        sidebarTabManager = nil
        sidebarLayout = nil
        sidebarSplitView = nil
        sidebarBackgroundView = nil
        sidebarChromeView = nil
        sidebarChromeTrailingConstraint = nil
        sidebarExpandedConstraints = []
        sidebarCollapsedConstraint = nil
        terminalTitlebarFiller = nil
        terminalTitlebarFillerBottom = nil
        paneTabBarTopConstraint = nil
        paneTabBarHeight = nil
        editorHostingView = nil
    }

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        self.relabelTabs()
        self.fixTabBar()
        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: true)
    }

    override func windowDidResignKey(_ notification: Notification) {
        super.windowDidResignKey(notification)
        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: false)
    }

    override func windowDidMove(_ notification: Notification) {
        super.windowDidMove(notification)
        self.fixTabBar()

        // Whenever we move save our last position for the next start.
        LastWindowPosition.shared.save(window)
    }

    override func windowDidResize(_ notification: Notification) {
        super.windowDidResize(notification)

        // Whenever we resize save our last position and size for the next start.
        LastWindowPosition.shared.save(window)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        // Whenever we get focused, use that as our last window position for
        // restart. This differs from Terminal.app but matches iTerm2 behavior
        // and I think its sensible.
        LastWindowPosition.shared.save(window)

        // Remember our last main
        Self.lastMain = self
    }

    // Called when the window will be encoded. We handle the data encoding here in the
    // window controller.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let data = TerminalRestorableState(from: self)
        data.encode(with: state)
    }

    // MARK: First Responder

    @IBAction func newWindow(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newWindow(surface: surface)
    }

    @IBAction func newTab(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    @IBAction func closeTab(_ sender: Any?) {
        guard let window = window else { return }
        guard window.tabGroup?.windows.count ?? 0 > 1 else {
            closeWindow(sender)
            return
        }

        guard surfaceTree.contains(where: { $0.needsConfirmQuit }) else {
            closeTabImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabImmediately()
        }
    }

    @IBAction func closeOtherTabs(_ sender: Any?) {
        guard let window = window else { return }
        guard let tabGroup = window.tabGroup else { return }

        // If we only have one window then we have no other tabs to close
        guard tabGroup.windows.count > 1 else { return }

        // Check if we have to confirm close.
        guard tabGroup.windows.contains(where: { window in
            // Ignore ourself
            if window == self.window { return false }

            // Ignore non-terminals
            guard let controller = window.windowController as? TerminalController else {
                return false
            }

            // Check if any surfaces require confirmation
            return controller.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }) else {
            self.closeOtherTabsImmediately()
            return
        }

        confirmClose(
            messageText: "Close Other Tabs?",
            informativeText: "At least one other tab still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeOtherTabsImmediately()
        }
    }

    @IBAction func closeTabsOnTheRight(_ sender: Any?) {
        guard let window = window else { return }
        guard let tabGroup = window.tabGroup else { return }
        guard let currentIndex = tabGroup.windows.firstIndex(of: window) else { return }

        let tabsToClose = tabGroup.windows.enumerated().filter { $0.offset > currentIndex }
        guard !tabsToClose.isEmpty else { return }

        let needsConfirm = tabsToClose.contains { (_, candidate) in
            guard let controller = candidate.windowController as? TerminalController else {
                return false
            }

            return controller.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }

        if !needsConfirm {
            self.closeTabsOnTheRightImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tabs on the Right?",
            informativeText: "At least one tab to the right still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabsOnTheRightImmediately()
        }
    }

    @IBAction func returnToDefaultSize(_ sender: Any?) {
        guard let window, let defaultSize else { return }
        defaultSize.apply(to: window)
    }

    @IBAction override func closeWindow(_ sender: Any?) {
        guard let window = window else { return }

        // We need to check all the windows in our tab group for confirmation
        // if we're closing the window. If we don't have a tabgroup for any
        // reason we check ourselves.
        let windows: [NSWindow] = window.tabGroup?.windows ?? [window]
        guard let confirmController = windows
            .compactMap({ $0.windowController as? TerminalController })
            .first(where: { $0.surfaceTree.contains(where: { $0.needsConfirmQuit }) })
        else {
            closeWindowImmediately()
            return
        }

        // We call confirmClose on the proper controller so the alert is
        // attached to the window that needs confirmation.
        confirmController.confirmClose(
            messageText: "Close Window?",
            informativeText: "All terminal sessions in this window will be terminated.",
        ) {
            self.closeWindowImmediately()
        }
    }

    @IBAction func toggleGhosttyFullScreen(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }

    @IBAction func toggleTerminalInspector(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleTerminalInspector(surface: surface)
    }

    // MARK: - TerminalViewDelegate

    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)

        // We always cancel our event listener
        surfaceAppearanceCancellables.removeAll()

        followWorkingDirectory(of: to)

        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)

        // We also want to get notified of certain changes to update our appearance.
        focusedSurface.$derivedConfig
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
        focusedSurface.$backgroundColor
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
    }

    /// Keeps the editor's idea of where its terminal is in step with the
    /// shell's.
    ///
    /// Subscribed here rather than read on demand because the interesting
    /// change is one nothing else in this window notices: a `cd` from one
    /// worktree of a repository to another leaves the title, the tab and the
    /// surface tree exactly as they were, and the only signal is the OSC 7
    /// the shell sends. The pane's divergence banner is that signal made
    /// visible.
    ///
    /// A nil surface leaves the last answer standing. Focus moving away is
    /// not the terminal moving — most often it has moved *into the editor* —
    /// and clearing the directory there would take the banner down at
    /// precisely the moment the reader looked at the file it is about.
    private func followWorkingDirectory(of surface: Ghostty.SurfaceView?) {
        guard let surface else { return }
        editorTerminalDirectoryCancellable = surface.$pwd
            .removeDuplicates()
            .sink { [weak self] pwd in
                self?.editorTerminalDirectory.path = (pwd?.isEmpty ?? true) ? nil : pwd
            }
    }

    private func syncAppearanceOnPropertyChange(_ surface: Ghostty.SurfaceView?) {
        guard let surface else { return }
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let surface else { return }
            guard let self else { return }
            guard self.focusedSurface == surface else { return }
            self.syncAppearance(surface.derivedConfig)
        }
    }

    // MARK: - Notifications

    @objc private func onMoveTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        // Get the move action
        guard let action = notification.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab else { return }
        guard action.amount != 0 else { return }

        // Determine our current selected index
        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        guard let selectedWindow = tabGroup.selectedWindow else { return }
        let tabbedWindows = tabGroup.windows
        guard tabbedWindows.count > 0 else { return }
        guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }

        // Determine the final index we want to insert our tab
        let finalIndex: Int
        if action.amount < 0 {
            finalIndex = selectedIndex - min(selectedIndex, -action.amount)
        } else {
            let remaining: Int = tabbedWindows.count - 1 - selectedIndex
            finalIndex = selectedIndex + min(remaining, action.amount)
        }

        // If our index is the same we do nothing
        guard finalIndex != selectedIndex else { return }

        // Get our target window
        let targetWindow = tabbedWindows[finalIndex]

        // Moving tabs on macOS 26 RC causes very nasty visual glitches in the titlebar tabs.
        // I believe this is due to messed up constraints for our hacky tab bar. I'd like to
        // find a better workaround. For now, this improves things dramatically.
        //
        // Reproduction: titlebar tabs, create two tabs, "move tab left"
        if #available(macOS 26, *) {
            if window is TitlebarTabsTahoeTerminalWindow {
                tabGroup.removeWindow(selectedWindow)
                targetWindow.addTabbedWindowSafely(selectedWindow, ordered: action.amount < 0 ? .below : .above)
                DispatchQueue.main.async {
                    selectedWindow.makeKey()
                }

                return
            }
        }

        // Begin a group of window operations to minimize visual updates
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        // Remove and re-add the window in the correct position
        tabGroup.removeWindow(selectedWindow)
        targetWindow.addTabbedWindowSafely(selectedWindow, ordered: action.amount < 0 ? .below : .above)

        // Ensure our window remains selected
        selectedWindow.makeKey()

        NSAnimationContext.endGrouping()
    }

    @objc private func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        // Get the tab index from the notification
        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }
        let tabIndex: Int32 = tabEnum.rawValue

        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        let tabbedWindows = tabGroup.windows

        // This will be the index we want to actual go to
        let finalIndex: Int

        // An index that is invalid is used to signal some special values.
        if tabIndex <= 0 {
            guard let selectedWindow = tabGroup.selectedWindow else { return }
            guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }

            if tabIndex == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue {
                if selectedIndex == 0 {
                    finalIndex = tabbedWindows.count - 1
                } else {
                    finalIndex = selectedIndex - 1
                }
            } else if tabIndex == GHOSTTY_GOTO_TAB_NEXT.rawValue {
                if selectedIndex == tabbedWindows.count - 1 {
                    finalIndex = 0
                } else {
                    finalIndex = selectedIndex + 1
                }
            } else if tabIndex == GHOSTTY_GOTO_TAB_LAST.rawValue {
                finalIndex = tabbedWindows.count - 1
            } else {
                return
            }
        } else {
            // The configured value is 1-indexed.
            guard tabIndex >= 1 else { return }

            // If our index is outside our boundary then we use the max
            finalIndex = min(Int(tabIndex - 1), tabbedWindows.count - 1)
        }

        guard finalIndex >= 0 else { return }
        let targetWindow = tabbedWindows[finalIndex]
        targetWindow.makeKeyAndOrderFront(nil)
    }

    @objc private func onCloseTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTab(self)
    }

    @objc private func onCloseOtherTabs(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeOtherTabs(self)
    }

    @objc private func onCloseTabsOnTheRight(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTabsOnTheRight(self)
    }

    @objc private func onCloseWindow(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeWindow(self)
    }

    @objc private func onResetWindowSize(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        returnToDefaultSize(nil)
    }

    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the fullscreen mode we want to toggle
        let fullscreenMode: FullscreenMode
        if let any = notification.userInfo?[Ghostty.Notification.FullscreenModeKey],
           let mode = any as? FullscreenMode {
            fullscreenMode = mode
        } else {
            Ghostty.logger.warning("no fullscreen mode specified or invalid mode, doing nothing")
            return
        }

        toggleFullscreen(mode: fullscreenMode)
    }

    struct DerivedConfig {
        let backgroundColor: Color
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: Ghostty.Config.MacOSTitlebarStyle
        let maximize: Bool
        let windowPositionX: Int16?
        let windowPositionY: Int16?

        init() {
            self.backgroundColor = Color(NSColor.windowBackgroundColor)
            self.macosWindowButtons = .visible
            self.macosTitlebarStyle = .default
            self.maximize = false
            self.windowPositionX = nil
            self.windowPositionY = nil
        }

        init(_ config: Ghostty.Config) {
            self.backgroundColor = config.backgroundColor
            self.macosWindowButtons = config.macosWindowButtons
            self.macosTitlebarStyle = config.macosTitlebarStyle
            self.maximize = config.maximize
            self.windowPositionX = config.windowPositionX
            self.windowPositionY = config.windowPositionY
        }
    }
}

// MARK: NSMenuItemValidation

extension TerminalController {
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeTabsOnTheRight):
            guard let window, let tabGroup = window.tabGroup else { return false }
            guard let currentIndex = tabGroup.windows.firstIndex(of: window) else { return false }
            return tabGroup.windows.indices.contains { $0 > currentIndex }

        case #selector(returnToDefaultSize):
            guard let window else { return false }

            // Native fullscreen windows can't revert to default size.
            if window.styleMask.contains(.fullScreen) {
                return false
            }

            // If we're fullscreen at all then we can't change size
            if fullscreenStyle?.isFullscreen ?? false {
                return false
            }

            // If our window is already the default size or we don't have a
            // default size, then disable.
            return defaultSize?.isChanged(for: window) ?? false

        default:
            return super.validateMenuItem(item)
        }
    }
}

// MARK: Default Size

extension TerminalController {
    /// The possible default sizes for a terminal. The size can't purely be known as a
    /// window frame because if we set `window-width/height` then it is based
    /// on content size.
    enum DefaultSize {
        /// A frame, set with `window.setFrame`
        case frame(NSRect)

        /// A content size, set with `window.setContentSize`
        case contentIntrinsicSize

        func isChanged(for window: NSWindow) -> Bool {
            switch self {
            case .frame(let rect):
                return window.frame != rect
            case .contentIntrinsicSize:
                guard let view = window.contentView else {
                    return false
                }

                return view.frame.size != view.intrinsicContentSize
            }
        }

        func apply(to window: NSWindow) {
            switch self {
            case .frame(let rect):
                window.setFrame(rect, display: true)
            case .contentIntrinsicSize:
                guard let size = window.contentView?.intrinsicContentSize else {
                    return
                }

                window.setContentSize(size)
                window.constrainToScreen()
            }
        }
    }

    /// Whether a window this app opens lands in the middle of its screen.
    ///
    /// The switch between two whole-app behaviours rather than a preference:
    /// centring and cascading contradict each other, so exactly one of them
    /// can be true, and naming it makes that visible from both sides.
    static let opensCentred = true

    /// What a terminal needs beside the sidebar before the window stops
    /// feeling cramped.
    ///
    /// Eighty columns is the width almost every tool still assumes when it
    /// wraps its own output, and at the editor's default monospace that is
    /// roughly this. Below it the sidebar is not what breaks — the *terminal*
    /// starts wrapping, and the sidebar gets blamed for the room it takes.
    static let minimumTerminalWidth: CGFloat = 720

    /// Where a freshly created window opens: centred, and wide enough for the
    /// sidebar and a terminal to coexist.
    ///
    /// Both halves are measured rather than chosen. The floor is the sidebar's
    /// *current* width — the one the reader last dragged to, not a constant —
    /// plus what a terminal needs, so widening the sidebar cannot squeeze the
    /// pane beside it in the next window that opens.
    ///
    /// Everything is clamped to the visible frame, which is what keeps this
    /// honest on a laptop screen: a preferred size larger than the display
    /// gives a window running off the bottom, and the menu bar and Dock are
    /// already excluded from `visibleFrame`.
    ///
    /// A static over values so the arithmetic is assertable without a window
    /// or a screen — the rest of this file's geometry follows the same rule.
    static func initialFrame(
        sidebarWidth: CGFloat,
        visible: NSRect,
        preferred: NSSize = NSSize(width: 1280, height: 820)
    ) -> NSRect {
        let width = min(max(preferred.width, sidebarWidth + minimumTerminalWidth), visible.width)
        let height = min(preferred.height, visible.height)

        return NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        ).integral
    }

    private var defaultSize: DefaultSize? {
        if derivedConfig.maximize, let screen = window?.screen ?? NSScreen.main {
            // Maximize takes priority, we take up the full screen we're on.
            return .frame(screen.visibleFrame)
        } else if focusedSurface?.initialSize != nil {
            // Initial size as requested by the configuration (e.g. `window-width`)
            // takes next priority.
            return .contentIntrinsicSize
        } else {
            return nil
        }
    }
}
