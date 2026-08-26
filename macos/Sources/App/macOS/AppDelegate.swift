import AppKit
import SwiftUI
import UserNotifications
import OSLog
import Sparkle
import GhosttyKit

class AppDelegate: NSObject,
                    ObservableObject,
                    NSApplicationDelegate,
                    UNUserNotificationCenterDelegate,
                    GhosttyAppDelegate {
    // The application logger. We should probably move this at some point to a dedicated
    // class/struct but for now it lives here! 🤷‍♂️
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: AppDelegate.self)
    )

    /// Various menu items so that we can programmatically sync the keyboard shortcut with the Ghostty config
    @IBOutlet private var menuAbout: NSMenuItem?
    @IBOutlet private var menuServices: NSMenu?
    @IBOutlet private var menuCheckForUpdates: NSMenuItem?
    @IBOutlet private var menuOpenConfig: NSMenuItem?
    @IBOutlet private var menuReloadConfig: NSMenuItem?
    @IBOutlet private var menuSecureInput: NSMenuItem?
    @IBOutlet private var menuQuit: NSMenuItem?

    @IBOutlet private var menuNewWindow: NSMenuItem?
    @IBOutlet private var menuNewTab: NSMenuItem?
    @IBOutlet private var menuSplitRight: NSMenuItem?
    @IBOutlet private var menuSplitLeft: NSMenuItem?
    @IBOutlet private var menuSplitDown: NSMenuItem?
    @IBOutlet private var menuSplitUp: NSMenuItem?
    @IBOutlet private var menuClose: NSMenuItem?
    @IBOutlet private var menuCloseTab: NSMenuItem?
    @IBOutlet private var menuCloseWindow: NSMenuItem?
    @IBOutlet private var menuCloseAllWindows: NSMenuItem?

    @IBOutlet private var menuUndo: NSMenuItem?
    @IBOutlet private var menuRedo: NSMenuItem?
    @IBOutlet private var menuCopy: NSMenuItem?
    @IBOutlet private var menuPaste: NSMenuItem?
    @IBOutlet private var menuPasteSelection: NSMenuItem?
    @IBOutlet private var menuSelectAll: NSMenuItem?
    @IBOutlet private var menuFindParent: NSMenuItem?
    @IBOutlet private var menuFind: NSMenuItem?
    @IBOutlet private var menuSelectionForFind: NSMenuItem?
    @IBOutlet private var menuScrollToSelection: NSMenuItem?
    @IBOutlet private var menuFindNext: NSMenuItem?
    @IBOutlet private var menuFindPrevious: NSMenuItem?
    @IBOutlet private var menuHideFindBar: NSMenuItem?

    @IBOutlet private var menuToggleVisibility: NSMenuItem?
    @IBOutlet private var menuToggleFullScreen: NSMenuItem?
    @IBOutlet private var menuBringAllToFront: NSMenuItem?
    @IBOutlet private var menuZoomSplit: NSMenuItem?
    @IBOutlet private var menuPreviousSplit: NSMenuItem?
    @IBOutlet private var menuNextSplit: NSMenuItem?
    @IBOutlet private var menuSelectSplitAbove: NSMenuItem?
    @IBOutlet private var menuSelectSplitBelow: NSMenuItem?
    @IBOutlet private var menuSelectSplitLeft: NSMenuItem?
    @IBOutlet private var menuSelectSplitRight: NSMenuItem?
    @IBOutlet private var menuReturnToDefaultSize: NSMenuItem?
    @IBOutlet private var menuFloatOnTop: NSMenuItem?
    @IBOutlet private var menuUseAsDefault: NSMenuItem?
    @IBOutlet private var menuSetAsDefaultTerminal: NSMenuItem?

    @IBOutlet private var menuIncreaseFontSize: NSMenuItem?
    @IBOutlet private var menuDecreaseFontSize: NSMenuItem?
    @IBOutlet private var menuResetFontSize: NSMenuItem?
    @IBOutlet private var menuChangeTitle: NSMenuItem?
    @IBOutlet private var menuChangeTabTitle: NSMenuItem?
    @IBOutlet private var menuReadonly: NSMenuItem?
    @IBOutlet private var menuQuickTerminal: NSMenuItem?
    @IBOutlet private var menuTerminalInspector: NSMenuItem?
    @IBOutlet private var menuCommandPalette: NSMenuItem?

    @IBOutlet private var menuEqualizeSplits: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerUp: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerDown: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerLeft: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerRight: NSMenuItem?

    /// The dock menu
    private var dockMenu: NSMenu = NSMenu()

    /// This is only true before application has become active.
    private var applicationHasBecomeActive: Bool = false

    /// This is set in applicationDidFinishLaunching with the system uptime so we can determine the
    /// seconds since the process was launched.
    private var applicationLaunchTime: TimeInterval = 0

    /// This is the current configuration from the Ghostty configuration that we need.
    private var derivedConfig: DerivedConfig = DerivedConfig()

    /// The ghostty global state. Only one per process.
    let ghostty: Ghostty.App

    /// The global undo manager for app-level state such as window restoration.
    lazy var undoManager = ExpiringUndoManager()

    /// The current state of the quick terminal.
    private var quickTerminalControllerState: QuickTerminalState = .uninitialized

    /// Whether the quick terminal has already been initialized.
    var quickControllerInitialized: Bool {
        if case .initialized = quickTerminalControllerState {
            return true
        }
        return false
    }

    /// Our quick terminal. This starts out uninitialized and only initializes if used.
    var quickController: QuickTerminalController {
        switch quickTerminalControllerState {
        case .initialized(let controller):
            return controller

        case .pendingRestore(let state):
            let controller = QuickTerminalController(
                ghostty,
                position: derivedConfig.quickTerminalPosition,
                baseConfig: state.baseConfig,
                restorationState: state
            )
            quickTerminalControllerState = .initialized(controller)
            return controller

        case .uninitialized:
            let controller = QuickTerminalController(
                ghostty,
                position: derivedConfig.quickTerminalPosition,
                restorationState: nil
            )
            quickTerminalControllerState = .initialized(controller)
            return controller
        }
    }

    /// Manages updates
    let updateController = UpdateController()
    var updateViewModel: UpdateViewModel {
        updateController.viewModel
    }

    /// The elapsed time since the process was started
    var timeSinceLaunch: TimeInterval {
        return ProcessInfo.processInfo.systemUptime - applicationLaunchTime
    }

    /// Tracks the windows that we hid for toggleVisibility.
    private(set) var hiddenState: ToggleVisibilityState?

    /// The observer for the app appearance.
    private var appearanceObserver: NSKeyValueObservation?

    /// Signals
    private var signals: [DispatchSourceSignal] = []

    @MainActor private lazy var menuShortcutManager = Ghostty.MenuShortcutManager()

    override init() {
        // Phantom keeps its own config directory, so the core must be pointed
        // at it explicitly — its default-file discovery resolves to Ghostty's
        // directory, which would leave the settings window editing a file the
        // renderer never reads.
        let configPath = ProcessInfo.processInfo.environment["GHOSTTY_CONFIG_PATH"]
            ?? GuiConfigStore.bootstrap()
        ghostty = Ghostty.App(configPath: configPath)
        super.init()

        ghostty.delegate = self
    }

    // MARK: - NSApplicationDelegate

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if
            let suite = UserDefaults.ghosttySuite,
            let clear = ProcessInfo.processInfo.environment["GHOSTTY_CLEAR_USER_DEFAULTS"],
            (clear as NSString).boolValue {
            UserDefaults.ghostty.removePersistentDomain(forName: suite)
        }
        #endif
        UserDefaults.ghostty.register(defaults: [
            // Disable the automatic full screen menu item because we handle
            // it manually.
            "NSFullScreenMenuItemEverywhere": false,

            // On macOS 26 RC1, the autofill heuristic controller causes unusable levels
            // of slowdowns and CPU usage in the terminal window under certain [unknown]
            // conditions. We don't know exactly why/how. This disables the full heuristic
            // controller.
            //
            // Practically, this means things like SMS autofill don't work, but that is
            // a desirable behavior to NOT have happen for a terminal, so this is a win.
            // Manual autofill via the `Edit => AutoFill` menu item still work as expected.
            "NSAutoFillHeuristicControllerEnabled": false,
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Materialize the GUI settings file (and its config-file include)
        // so fork defaults like the sidebar exist even before the
        // settings window is ever opened.
        _ = GuiConfigStore.shared

        // System settings overrides
        UserDefaults.ghostty.register(defaults: [
            // Disable this so that repeated key events make it through to our terminal views.
            "ApplePressAndHoldEnabled": false,
        ])

        /// Shorten the wait before a tooltip appears. Outside the
        /// `MCPServer.isTesting` guard below: that guard exists for the calls
        /// that write into the reader's own files, and this one writes nothing
        /// — it sets a number on an AppKit object that dies with the process.
        /// A test host wants it too, because running it is what proves the
        /// private API it resolves has not gone away.
        ToolTipDelay.applyInitialDelay()

        /// Age out undo histories for files nobody has come back to. Off the
        /// main thread because it walks a directory, and skipped under test
        /// because the test bundle is hosted inside the app and would prune
        /// the real one.
        if !MCPServer.isTesting {
            DispatchQueue.global(qos: .utility).async { EditorUndoArchive.prune() }
        }

        // Put the chosen app icon back on. The override is in-memory only
        // (`NSApp.applicationIconImage`), so every launch starts from the
        // compiled-in icon until this runs.
        PhantomAppIconStore.restore()

        // Store our start time
        applicationLaunchTime = ProcessInfo.processInfo.systemUptime

        // Check if secure input was enabled when we last quit.
        if UserDefaults.ghostty.bool(forKey: "SecureInput") != SecureInput.shared.enabled {
            toggleSecureInput(self)
        }

        // Initial config loading
        ghosttyConfigDidChange(config: ghostty.config)

        // Bring already-installed agent hooks up to this build's version.
        //
        // Installing them once was a one-way door: the check for "installed"
        // asks whether the file is there, so a script written by an older
        // Phantom stayed, the UI reported it as installed, and the only
        // action offered was to remove it. A hook from before session ids
        // existed therefore went on not capturing them — which looks exactly
        // like the resume being broken. These files are generated and never
        // hand-edited, so rewriting one costs nothing.
        /// Not from a test host. `xcodebuild test` hosts the bundle inside the
        /// app, so this runs during a suite — and every line of it writes into
        /// the reader's own home: their agents' hook scripts, and below, their
        /// MCP entries. A suite that rewrites somebody's configuration as a
        /// side effect of running can break their setup while reporting green,
        /// which is what the socket guard in `MCPServer` was added for and the
        /// same reasoning applies here.
        ///
        /// Scoped to the writes rather than returning early: everything after
        /// them is this app's own state, and a test host wants it.
        if !MCPServer.isTesting {
            ClaudeHooksInstaller.repairIfStale()
            CodexHooksInstaller.repairIfStale()
            OpenCodeHooksInstaller.repairIfStale()
            AntigravityHooksInstaller.repairIfStale()
            KimiHooksInstaller.repairIfStale()
            PiHooksInstaller.repairIfStale()
        }

        // The one object that puts the permission question on screen, and it
        // starts before the listener does: a question raised with nobody
        // watching is a `pending` nothing will ever answer, and the store
        // refuses every later question while one is pending.
        MCPPermissionPrompt.shared.start()

        // The MCP listener, beside the hooks because it is the same idea: a
        // rendezvous the agents running inside this app's terminals can find.
        // The socket is named after the bundle, so a debug build and a
        // release one running together each answer for themselves.
        MCPServer.shared.start()

        // The MCP entry in each agent's own configuration, kept current the
        // same way the hooks above are: repaired when it is behind this build,
        // never installed uninvited. The command it registers is this bundle's
        // own binary, so a Phantom that moved on disk leaves an entry pointing
        // at nothing until this rewrites it.
        /// Behind the same guard, and for the same reason: this writes into
        /// four other programs' configuration files.
        if !MCPServer.isTesting { MCPServerRegistration.repairAll() }

        // Watching for the moments a window can become unreachable, before
        // any window exists to have them. Development builds only; see
        // `WindowBreadcrumbs` for the incident this observes for.
        WindowBreadcrumbs.startWatching()

        // Restore our own persisted session. macOS's restoration has either
        // run already (restoring, or standing down in favor of ours), or
        // runs right after launch — it never creates a window when our store
        // has a session. This must happen before `applicationDidBecomeActive`
        // decides whether to open a default window, so a CLI launch restores
        // too (see `PhantomSessionStore`).
        // Restore takes responsibility for the windows when it has a session
        // to bring back. Asked for its answer rather than discarded, because
        // that answer is what decides whether anything else may open one.
        sessionWasRestored = PhantomSessionStore.shared.restoreIfNeeded()

        // Start our update checker.
        updateController.startUpdater()

        // Register our service provider. This must happen after everything is initialized.
        NSApp.servicesProvider = ServiceProvider()

        // This registers the Ghostty => Services menu to exist.
        NSApp.servicesMenu = menuServices

        // Setup a local event monitor for app-level keyboard shortcuts. See
        // localEventHandler for more info why.
        _ = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown],
            handler: localEventHandler)

        // Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quickTerminalDidChangeVisibility),
            name: .quickTerminalDidChangeVisibility,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyBellDidRing(_:)),
            name: .ghosttyBellDidRing,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalWindowHasBell(_:)),
            name: .terminalWindowBellDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyNewWindow(_:)),
            name: Ghostty.Notification.ghosttyNewWindow,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyNewTab(_:)),
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)

        // Configure user notifications
        let actions = [
            UNNotificationAction(identifier: Ghostty.userNotificationActionShow, title: "Show")
        ]

        let center = UNUserNotificationCenter.current()

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Ghostty.userNotificationCategory,
                actions: actions,
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
        ])
        center.delegate = self

        // Observe our appearance so we can report the correct value to libghostty.
        self.appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance,
             options: [.new, .initial]
        ) { _, change in
            guard let appearance = change.newValue else { return }
            guard let app = self.ghostty.app else { return }
            let scheme: ghostty_color_scheme_e
            if appearance.isDark {
                scheme = GHOSTTY_COLOR_SCHEME_DARK
            } else {
                scheme = GHOSTTY_COLOR_SCHEME_LIGHT
            }

            ghostty_app_set_color_scheme(app, scheme)
        }

        // Setup our menu
        setupMenuImages()

        // Setup signal handlers
        setupSignals()

        switch Ghostty.launchSource {
        case .app:
            // Don't have to do anything.
            break

        case .zig_run, .cli:
            // Part of launch services (clicking an app, using `open`, etc.) activates
            // the application and brings it to the front. When using the CLI we don't
            // get this behavior, so we have to do it manually.

            // This never gets called until we click the dock icon. This forces it
            // activate immediately.
            applicationDidBecomeActive(.init(name: NSApplication.didBecomeActiveNotification))

            // We run in the background, this forces us to the front.
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.unhide(nil)
                NSApp.arrangeInFront(nil)
            }
        }

        // Once macOS's restoration session has fully settled, record the
        // resulting window set so the next launch restores from our store
        // (see `PhantomSessionStore`).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidFinishRestoringWindows(_:)),
            name: NSApplication.didFinishRestoringWindowsNotification,
            object: nil
        )
    }

    @objc private func applicationDidFinishRestoringWindows(_ notification: Notification) {
        PhantomSessionStore.shared.scheduleSave()
    }

    func applicationDidHide(_ notification: Notification) {
        // Keep track of our hidden state to restore properly
        self.hiddenState = .init()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // If we're back manually then clear the hidden state because macOS handles it.
        self.hiddenState = nil

        // First launch stuff
        if !applicationHasBecomeActive {
            applicationHasBecomeActive = true

            // Let's launch our first window. We only do this if we have no other windows. It
            // is possible to have other windows in a few scenarios:
            //   - if we're opening a URL since `application(_:openFile:)` is called before this.
            //   - if we're restoring from persisted state
            openInitialWindowIfNothingIsOnScreen()
        }
    }

    /// Whether our own session restore claimed the windows for this launch.
    ///
    /// The whole point is that exactly one thing decides. Restore presents
    /// its windows from async blocks, so any check that runs in between sees
    /// an empty screen and cannot tell "restore has not got there yet" from
    /// "nothing is coming".
    private var sessionWasRestored = false

    /// Opens the first window when nothing else is going to.
    ///
    /// Two conditions, and both were wrong here at some point. It asks about
    /// *visibility* rather than `TerminalController.all.isEmpty`, because
    /// `NSApplication.windows` counts windows that exist and are not visible.
    /// And it defers entirely to restore when restore had a session, because
    /// visibility alone cannot distinguish a screen that will fill in a
    /// moment from one that never will.
    ///
    /// Getting the second condition wrong leaked a window per launch: the
    /// check ran while restore was still presenting, decided the screen was
    /// empty, and added one. That window was then saved into the session, so
    /// the next launch restored it *and* added another — one more every time
    /// the app was opened.
    private func openInitialWindowIfNothingIsOnScreen() {
        guard derivedConfig.initialWindow else { return }
        guard !sessionWasRestored else { return }
        guard !TerminalController.hasVisibleWindow else { return }

        undoManager.disableUndoRegistration()
        _ = TerminalController.newWindow(ghostty)
        undoManager.enableUndoRegistration()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        WindowBreadcrumbs.note(
            "lastWindowClosed: AppKit believes the last window closed; "
            + "answering \(derivedConfig.shouldQuitAfterLastWindowClosed), "
            + "app windows=\(NSApp.windows.count) "
            + "terminals=\(TerminalController.all.count)")
        return derivedConfig.shouldQuitAfterLastWindowClosed
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let event = NSApp.currentEvent {
            WindowBreadcrumbs.note(
                "shouldTerminate: event=\(event.type.rawValue) "
                + "eventWindow=\(event.window?.windowNumber ?? -1) "
                + "key=\(event.type == .keyDown ? event.charactersIgnoringModifiers ?? "" : "") "
                + "windows=\(NSApp.windows.count)")
        } else {
            WindowBreadcrumbs.note(
                "shouldTerminate: no current event (programmatic) windows=\(NSApp.windows.count)")
        }
        /// The session as it stands at the moment the reader asked to quit,
        /// while every window they have is certainly still theirs. Everything
        /// after this point is the quit happening — windows the review closes,
        /// windows AppKit tears down — and none of it may make the session
        /// smaller, which is what `quitBegan` goes on to enforce. Recording it
        /// here rather than relying on the last debounced save is what keeps a
        /// window closed a moment before quitting from coming back.
        PhantomSessionStore.shared.saveNow()
        PhantomSessionStore.shared.quitBegan()

        let windows = NSApplication.shared.windows
        if windows.isEmpty { return .terminateNow }

        // If we've already accepted to install an update, then we don't need to
        // confirm quit. The user is already expecting the update to happen.
        if updateController.shouldTerminateWithoutWarning {
            return .terminateNow
        }

        // If the user is shutting down, restarting, or logging out, we don't confirm quit.
        why: if let event = NSAppleEventManager.shared().currentAppleEvent {
            // If all Ghostty windows are in the background (i.e. you Cmd-Q from the Cmd-Tab
            // view), then this is null. I don't know why (pun intended) but we have to
            // guard against it.
            guard let keyword = AEKeyword("why?") else { break why }

            if let why = event.attributeDescriptor(forKeyword: keyword) {
                switch why.typeCodeValue {
                case kAEShutDown, kAERestart, kAEReallyLogOut:
                    return .terminateNow

                default:
                    break
                }
            }
        }

        // If our app says we don't need to confirm, we can exit now.
        if !ghostty.needsConfirmQuit { return .terminateNow }

        return terminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowBreadcrumbs.note("willTerminate: the app is going down through AppKit")

        // The socket file outlives the process that bound it, and a stale one
        // is a path a client connects to and waits on forever.
        MCPServer.shared.stop()

        // We have no notifications we want to persist after death,
        // so remove them all now. In the future we may want to be
        // more selective and only remove surface-targeted notifications.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()

        // Final authoritative write of our own session store.
        PhantomSessionStore.shared.saveNow()

        // Quitting with files open is the ordinary way to quit, and it is the
        // one path where no tab ever closes — so this is the only chance the
        // open files get to have their undo history written down.
        var open: [String: String] = [:]
        for controller in TerminalController.all {
            for (path, document) in controller.editorCenter.documents {
                open[path] = document.currentText
            }
        }
        EditorUndoCenter.shared.persistOpenFiles(texts: open)
    }

    /// This is called when the application is already open and someone double-clicks the icon
    /// or clicks the dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If we have visible windows then we allow macOS to do its default behavior
        // of focusing one of them.
        //
        // "Visible" is macOS's word, and it includes a window orphaned on a
        // Space that no longer exists — one Mission Control lists but cannot
        // raise, and focusing does nothing the reader can see. So the default
        // behavior is verified rather than trusted: if a moment later nothing
        // terminal is key or on the active Space, the window is pulled onto
        // this one. See `WindowGhostRescue` for the incident this answers.
        guard !flag else {
            WindowBreadcrumbs.note("reopen: deferring to macOS, hasVisibleWindows=true")
            WindowGhostRescue.verifyReopenLandedSomewhere()
            return true
        }

        // If the application isn't active yet then we don't want to process
        // this because we're not ready. This happens sometimes in Xcode runs
        // but I haven't seen it happen in releases. I'm unsure why.
        guard applicationHasBecomeActive else { return true }

        /// No visible windows. The session, if there is one, is what the
        /// reader is reopening the app to get back — see `newWindow`.
        ///
        /// **Everything below runs a turn later, and that is the fix, not a
        /// nicety.** Window work performed inside this delegate call is
        /// inside AppKit's reopen transaction, and windows built there kept
        /// reaching the screen half-made: first the reveal alone was
        /// deferred and the *front* window started committing — but the tab
        /// joins still ran in here, and a reopen-restored group kept one or
        /// two members AppKit-visible and WindowServer-offscreen. Clicking
        /// those rows closed the visible window and showed nothing, which
        /// read as the app dying; the same group also answered "last
        /// window" queries in join order rather than launch order, which is
        /// what made a new terminal land second-to-last. A launch restore
        /// never showed any of it — launch is not inside this dispatch. So
        /// the whole restore leaves it too, and the return value is decided
        /// from a peek at the session file, which counts without decoding.
        return !Self.scheduleReopenWork(for: self)
    }

    /// The reopen's window work, scheduled off the reopen transaction.
    ///
    /// Answers whether there is work at all — the caller's return value —
    /// from state alone: a readable non-empty session that is allowed to
    /// restore, or no reachable terminal window (which means a blank one
    /// must open). Split from the delegate method and static so the
    /// decision can be pinned by tests without an application.
    static func scheduleReopenWork(for delegate: AppDelegate) -> Bool {
        let store = PhantomSessionStore.shared
        let mayRestore = PhantomSessionStore.mayRestore(
            windowSaveState: delegate.ghostty.config.windowSaveState)
        let hasSession = mayRestore && store.hasRestorableSession
        let needsWindow = !PhantomSessionStore.hasReachableTerminalWindows

        guard hasSession || needsWindow else { return false }

        DispatchQueue.main.async {
            if store.restoreIfNeeded() { return }
            guard !PhantomSessionStore.hasReachableTerminalWindows else { return }
            _ = TerminalController.newWindow(delegate.ghostty)
        }
        return true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // Ghostty will validate as well but we can avoid creating an entirely new
        // surface by doing our own validation here. We can also show a useful error
        // this way.

        guard let intent = ExternalOpenIntent.decide(forPath: filename) else { return false }

        /// A file without the executable bit goes to the editor rather than
        /// down the terminal's path, which runs it. Upstream's answer — run
        /// it, as Terminal and iTerm2 do — is right for a terminal emulator
        /// and wrong for this, where opening `config.ts` from the Finder fed
        /// a source file to a login shell.
        ///
        /// Before any window exists, so it may have to make one: this is
        /// called during launch, ahead of `applicationDidBecomeActive`.
        if intent == .edit {
            let controller = TerminalController.preferredParent
                ?? TerminalController.newWindow(ghostty)
            controller.openFileInEditor(URL(fileURLWithPath: filename))
            return true
        }

        let isDirectory = ObjCBool(intent == .workingDirectory)

        // Set to true if confirmation is required before starting up the
        // new terminal.
        var requiresConfirm: Bool = false

        // Initialize the surface config which will be used to create the tab or window for the opened file.
        var config = Ghostty.SurfaceConfiguration()

        if isDirectory.boolValue {
            // When opening a directory, check the configuration to decide
            // whether to open in a new tab or new window.
            config.workingDirectory = filename
        } else {
            // Unconditionally require confirmation in the file execution case.
            // In the future I have ideas about making this more fine-grained if
            // we can not inherit of unsandboxed state. For now, we need to confirm
            // because there is a sandbox escape possible if a sandboxed application
            // somehow is tricked into `open`-ing a non-sandboxed application.
            requiresConfirm = true

            // When opening a file, we want to execute the file. To do this, we
            // don't override the command directly, because it won't load the
            // profile/rc files for the shell, which is super important on macOS
            // due to things like Homebrew. Instead, we set the command to
            // `<filename>; exit` which is what Terminal and iTerm2 do.
            config.initialInput = "\(Ghostty.Shell.quote(filename)); exit\n"

            // For commands executed directly, we want to ensure we wait after exit
            // because in most cases scripts don't block on exit and we don't want
            // the window to just flash closed once complete.
            config.waitAfterCommand = true

            // Set the parent directory to our working directory so that relative
            // paths in scripts work.
            config.workingDirectory = (filename as NSString).deletingLastPathComponent
        }

        if requiresConfirm {
            // Confirmation required. We use an app-wide NSAlert for now. In the future we
            // may want to show this as a sheet on the focused window (especially if we're
            // opening a tab). I'm not sure.
            let alert = NSAlert()
            alert.messageText = "Allow \(appDisplayName) to execute \"\(filename)\"?"
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                break

            default:
                return false
            }
        }

        switch ghostty.config.macosDockDropBehavior {
        case .new_tab:
            _ = TerminalController.newTab(
                ghostty,
                from: TerminalController.preferredParent?.window,
                withBaseConfig: config
            )
        case .new_window: _ = TerminalController.newWindow(ghostty, withBaseConfig: config)
        }

        return true
    }

    /// Setup signal handlers
    private func setupSignals() {
        // Register a signal handler for config reloading. It appears that all
        // of this is required. I've commented each line because its a bit unclear.
        // Warning: signal handlers don't work when run via Xcode. They have to be
        // run on a real app bundle.

        // We need to ignore signals we register with makeSignalSource or they
        // don't seem to handle.
        signal(SIGUSR2, SIG_IGN)

        // Make the signal source and register our event handle. We keep a weak
        // ref to ourself so we don't create a retain cycle.
        let sigusr2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        sigusr2.setEventHandler { [weak self] in
            guard let self else { return }
            Ghostty.logger.info("reloading configuration in response to SIGUSR2")
            self.ghostty.reloadConfig()
        }

        // The signal source starts unactivated, so we have to resume it once
        // we setup the event handler.
        sigusr2.resume()

        // We need to keep a strong reference to it so it isn't disabled.
        signals.append(sigusr2)
    }

    // MARK: Notifications and Events

    /// This handles events from the NSEvent.addLocalEventMonitor. We use this so we can get
    /// events without any terminal windows open.
    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        return switch event.type {
        case .keyDown:
            localEventKeyDown(event)

        default:
            event
        }
    }

    private func localEventKeyDown(_ event: NSEvent) -> NSEvent? {
        // If the tab overview is visible and escape is pressed, close it.
        // This can't POSSIBLY be right and is probably a FirstResponder problem
        // that we should handle elsewhere in our program. But this works and it
        // is guarded by the tab overview currently showing.
        if event.keyCode == 0x35, // Escape key
           let window = NSApp.keyWindow,
           let tabGroup = window.tabGroup,
           tabGroup.isOverviewVisible {
            window.toggleTabOverview(nil)
            return nil
        }

        // If we have a main window then we don't process any of the keys
        // because we let it capture and propagate.
        guard NSApp.mainWindow == nil else { return event }

        // If this event as-is would result in a key binding then we send it.
        if let app = ghostty.app, let config = ghostty.config.config {
            var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            let match = (event.characters ?? "").withCString { ptr in
                ghosttyEvent.text = ptr
                if !ghostty_config_key_is_binding(config, ghosttyEvent) {
                    return false
                }

                return ghostty_app_key(app, ghosttyEvent)
            }

            // If the key was handled by Ghostty we stop the event chain. If
            // the key wasn't handled then we let it fall through and continue
            // processing. This is important because some bindings may have no
            // affect at this scope.
            if match {
                return nil
            }
        }

        // If this event would be handled by our menu then we do nothing.
        if let mainMenu = NSApp.mainMenu,
           mainMenu.performKeyEquivalent(with: event) {
            return nil
        }

        // If we reach this point then we try to process the key event
        // through the Ghostty key mechanism.

        // Ghostty must be loaded
        guard let ghostty = self.ghostty.app else { return event }

        // Build our event input and call ghostty
        if ghostty_app_key(ghostty, event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)) {
            // The key was used so we want to stop it from going to our Mac app
            Ghostty.logger.debug("local key event handled event=\(event, privacy: .public)")
            return nil
        }

        return event
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        syncFloatOnTopMenu(notification.object as? NSWindow)
    }

    @objc private func quickTerminalDidChangeVisibility(_ notification: Notification) {
        guard let quickController = notification.object as? QuickTerminalController else { return }
        self.menuQuickTerminal?.state = if quickController.visible { .on } else { .off }
    }

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a surface one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        ghosttyConfigDidChange(config: config)
    }

    @objc private func ghosttyBellDidRing(_ notification: Notification) {
        if ghostty.config.bellFeatures.contains(.system) {
            NSSound.beep()
        }

        if ghostty.config.bellFeatures.contains(.audio) {
            if let configPath = ghostty.config.bellAudioPath,
               let sound = NSSound(contentsOfFile: configPath.path, byReference: false) {
                sound.volume = ghostty.config.bellAudioVolume
                sound.play()
            }
        }

        if ghostty.config.bellFeatures.contains(.attention) {
            // Bounce the dock icon if we're not focused.
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    @objc private func terminalWindowHasBell(_ notification: Notification) {
        guard notification.object is BaseTerminalController else { return }
        syncDockBadge()
    }

    private func requestBadgeAuthorizationAndSet(_ center: UNUserNotificationCenter) {
        center.requestAuthorization(options: [.badge]) { granted, error in
            if let error = error {
                Self.logger.warning("Error requesting badge authorization: \(error, privacy: .public)")
                return
            }

            // Permission granted, set the badge
            if granted {
                DispatchQueue.main.async {
                    self.setDockBadge()
                }
            }
        }
    }

    private func syncDockBadge() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized:
                // If we're authorized and allow badges, then set the badge.
                if settings.badgeSetting == .enabled {
                    DispatchQueue.main.async {
                        self.setDockBadge()
                    }
                } else if settings.badgeSetting == .notSupported {
                    // If badge setting is not supported, we may be in a sandbox that doesn't allow it.
                    // We can still attempt to set the badge and hope for the best, but we should also
                    // request authorization just in case it is a permissions issue.
                    self.requestBadgeAuthorizationAndSet(center)
                }

            case .notDetermined:
                // Not determined yet, request authorization for badge
                self.requestBadgeAuthorizationAndSet(center)

            case .denied, .provisional, .ephemeral:
                // In these known non-authorized states, do not attempt to set the badge.
                break

            @unknown default:
                // Handle future unknown states by doing nothing.
                break
            }
        }
    }

    @objc private func ghosttyNewWindow(_ notification: Notification) {
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration

        /// With the sidebar on, ⌘N makes a terminal in the sidebar, not a
        /// loose window. The fork replaced macOS tabs with the sidebar, so
        /// "window" stopped being a unit the reader ever asked for — every
        /// terminal is a row, and a window outside the group is the ghost
        /// row: selected in parallel, listed by the Dock under the same
        /// name, saved by the session store as a second group and restored
        /// split forever. The reader who reported this created "tabs" with
        /// ⌘N all along — the expectation is the design.
        if ghostty.config.sidebar, let parent = TerminalController.liveTabParent() {
            _ = TerminalController.newTab(ghostty, from: parent, withBaseConfig: config)
            return
        }
        _ = TerminalController.newWindow(ghostty, withBaseConfig: config)
    }

    @objc private func ghosttyNewTab(_ notification: Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard let window = surfaceView.window else { return }

        // We only want to listen to new tabs if the focused parent is
        // a regular terminal controller.
        guard window.windowController is TerminalController else { return }

        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration

        _ = TerminalController.newTab(ghostty, from: window, withBaseConfig: config)
    }

    private func setDockBadge() {
        let bellCount = NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .reduce(0) { $0 + ($1.bell ? 1 : 0) }
        let wantsBadge = ghostty.config.bellFeatures.contains(.attention) && bellCount > 0
        let label = wantsBadge ? (bellCount > 99 ? "99+" : String(bellCount)) : nil
        NSApp.dockTile.badgeLabel = label
        NSApp.dockTile.display()
    }

    private func ghosttyConfigDidChange(config: Ghostty.Config) {
        // Update the config we need to store
        self.derivedConfig = DerivedConfig(config)

        // Depending on the "window-save-state" setting we have to set the NSQuitAlwaysKeepsWindows
        // configuration. This is the only way to carefully control whether macOS invokes the
        // state restoration system.
        switch config.windowSaveState {
        case "never": UserDefaults.ghostty.setValue(false, forKey: "NSQuitAlwaysKeepsWindows")
        case "always": UserDefaults.ghostty.setValue(true, forKey: "NSQuitAlwaysKeepsWindows")
        case "default": fallthrough
        default: UserDefaults.ghostty.removeObject(forKey: "NSQuitAlwaysKeepsWindows")
        }

        // Sync our auto-update settings. If SUEnableAutomaticChecks (in our Info.plist) is
        // explicitly false (NO), auto-updates are disabled. Otherwise, we use the behavior
        // defined by our "auto-update" configuration (if set) or fall back to Sparkle
        // user-based defaults.
        if Bundle.main.infoDictionary?["SUEnableAutomaticChecks"] as? Bool == false {
            updateController.updater.automaticallyChecksForUpdates = false
            updateController.updater.automaticallyDownloadsUpdates = false
        } else if let autoUpdate = config.autoUpdate {
            updateController.updater.automaticallyChecksForUpdates =
                autoUpdate == .check || autoUpdate == .download
            updateController.updater.automaticallyDownloadsUpdates =
                autoUpdate == .download
            /*
             To test `auto-update` easily, uncomment the line below and
             delete `SUEnableAutomaticChecks` in Ghostty-Info.plist.

             Note: When `auto-update = download`, you may need to
             `Clean Build Folder` if a background install has already begun.
             */
            // updateController.updater.checkForUpdatesInBackground()
        }

        // Config could change keybindings, so update everything that depends on that
        DispatchQueue.main.async {
            self.syncMenuShortcuts(config)
        }
        TerminalController.all.forEach { $0.relabelTabs() }

        // Update our badge since config can change what we show.
        syncDockBadge()

        // Config could change window appearance. We wrap this in an async queue because when
        // this is called as part of application launch it can deadlock with an internal
        // AppKit mutex on the appearance.
        DispatchQueue.main.async { self.syncAppearance(config: config) }

        // Decide whether to hide/unhide app from dock and app switcher
        switch config.macosHidden {
        case .never:
            NSApp.setActivationPolicy(.regular)

        case .always:
            NSApp.setActivationPolicy(.accessory)
        }

        // If we have configuration errors, we need to show them.
        let c = ConfigurationErrorsController.sharedInstance
        c.errors = config.errors
        if c.errors.count > 0 {
            if c.window == nil || !c.window!.isVisible {
                c.showWindow(self)
            }
        }

        // We need to handle our global event tap depending on if there are global
        // events that we care about in Ghostty.
        if ghostty_app_has_global_keybinds(ghostty.app!) {
            if timeSinceLaunch > 5 {
                // If the process has been running for awhile we enable right away
                // because no windows are likely to pop up.
                GlobalEventTap.shared.enable()
            } else {
                // If the process just started, we wait a couple seconds to allow
                // the initial windows and so on to load so our permissions dialog
                // doesn't get buried.
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
                    GlobalEventTap.shared.enable()
                }
            }
        } else {
            GlobalEventTap.shared.disable()
        }
    }

    /// Sync the appearance of our app with the theme specified in the config.
    private func syncAppearance(config: Ghostty.Config) {
        NSApplication.shared.appearance = .init(ghosttyConfig: config)
    }

    // MARK: - Restorable State

    /// We support NSSecureCoding for restorable state. Required as of macOS Sonoma (14) but a good idea anyways.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
        guard ghostty.config.windowSaveState != "never" else { return }

        // Encode our quick terminal state if we have it.
        switch quickTerminalControllerState {
        case .initialized(let controller) where controller.restorable:
            let data = QuickTerminalRestorableState(from: controller)
            data.encode(with: coder)

        case .pendingRestore(let state):
            state.encode(with: coder)

        default:
            break
        }
    }

    func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
        Self.logger.debug("application will restore window state")

        // Decode our quick terminal state.
        if ghostty.config.windowSaveState != "never",
            let state = QuickTerminalRestorableState(coder: coder) {
            quickTerminalControllerState = .pendingRestore(state)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive: UNNotificationResponse,
        withCompletionHandler: () -> Void
    ) {
        ghostty.handleUserNotification(response: didReceive)
        withCompletionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent: UNNotification,
        withCompletionHandler: (UNNotificationPresentationOptions) -> Void
    ) {
        let shouldPresent = ghostty.shouldPresentNotification(notification: willPresent)
        let options: UNNotificationPresentationOptions = shouldPresent ? [.banner, .sound] : []
        withCompletionHandler(options)
    }

    // MARK: - GhosttyAppDelegate

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        for c in TerminalController.all {
            for view in c.surfaceTree where view.id == uuid {
                return view
            }
        }

        return nil
    }

    // MARK: - Global State

    func setSecureInput(_ mode: Ghostty.SetSecureInput) {
        let input = SecureInput.shared
        switch mode {
        case .on:
            input.global = true

        case .off:
            input.global = false

        case .toggle:
            input.global.toggle()
        }
        self.menuSecureInput?.state = if input.global { .on } else { .off }
        UserDefaults.ghostty.set(input.global, forKey: "SecureInput")
    }

    // MARK: - IB Actions

    @IBAction func openConfig(_ sender: Any?) {
        SettingsWindowController.shared.show(ghostty: ghostty)
    }

    @IBAction func reloadConfig(_ sender: Any?) {
        ghostty.reloadConfig()
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        updateController.checkForUpdates()
        // UpdateSimulator.happyPath.simulate(with: updateViewModel)
    }

    @IBAction func newWindow(_ sender: Any?) {
        // Asking for a window with none open is the same request as
        // launching with none open, and deserves the same answer: the
        // session comes back. Quitting is not the only way to end up with
        // nothing on screen — closing the last window leaves the app
        // running, and a blank window there loses the arrangement just as
        // completely as a lost restore would. Once it has been brought
        // back, windows exist, so the next New Window is an ordinary one.
        if PhantomSessionStore.shared.restoreIfNeeded() { return }

        /// Same routing as the core's ⌘N — see `ghosttyNewWindow`. The menu
        /// item is the other spelling of the same request.
        if ghostty.config.sidebar, let parent = TerminalController.liveTabParent() {
            _ = TerminalController.newTab(ghostty, from: parent)
            return
        }
        _ = TerminalController.newWindow(ghostty)
    }

    @IBAction func newTab(_ sender: Any?) {
        _ = TerminalController.newTab(
            ghostty,
            from: TerminalController.preferredParent?.window
        )
    }

    @IBAction func closeAllWindows(_ sender: Any?) {
        TerminalController.closeAllWindows()
        AboutController.shared.hide()
    }

    @IBAction func showAbout(_ sender: Any?) {
        AboutController.shared.show()
    }

    @IBAction func showHelp(_ sender: Any) {
        guard let url = URL(string: "https://ghostty.org/docs") else { return }
        NSWorkspace.shared.open(url)
    }

    @IBAction func toggleSecureInput(_ sender: Any) {
        setSecureInput(.toggle)
    }

    @IBAction func toggleQuickTerminal(_ sender: Any) {
        quickController.toggle()
    }

    /// Toggles visibility of all Ghosty Terminal windows. When hidden, activates Ghostty as the frontmost application
    @IBAction func toggleVisibility(_ sender: Any) {
        // If we have focus, then we hide all windows.
        if NSApp.isActive {
            // Toggle visibility doesn't do anything if the focused window is native
            // fullscreen. This is only relevant if Ghostty is active.
            guard let keyWindow = NSApp.keyWindow,
                  !keyWindow.styleMask.contains(.fullScreen) else { return }

            NSApp.hide(nil)
            return
        }

        // If we're not active, we want to become active
        NSApp.activate(ignoringOtherApps: true)

        // Bring all windows to the front. Note: we don't use NSApp.unhide because
        // that will unhide ALL hidden windows. We want to only bring forward the
        // ones that we hid.
        hiddenState?.restore()
        hiddenState = nil
    }

    @IBAction func bringAllToFront(_ sender: Any) {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        NSApplication.shared.arrangeInFront(sender)
    }

    /// The undo manager belonging to whatever currently has focus, which is
    /// not always the app's.
    ///
    /// `NSResponder.undoManager` is the responder chain's own answer to the
    /// question: a responder that owns an undo stack returns it, and every
    /// other one passes the question upwards until it reaches the window,
    /// where `windowWillReturnUndoManager` hands back the app-level manager.
    /// So a focused terminal resolves to the very same object as
    /// `undoManager`, and a focused text view resolves to its own stack.
    ///
    /// Asked this way rather than by testing for a particular view class, so
    /// nothing here has to know which kinds of thing in this app can hold an
    /// undo stack — a view that grows one later is routed to correctly
    /// without this line changing.
    ///
    /// Nil when no window is key, and that case is the one worth keeping:
    /// closing the last window is exactly when "undo close window" has to
    /// still work, and by then there is no responder left to ask.
    private var focusedUndoManager: UndoManager? {
        NSApp.keyWindow?.firstResponder?.undoManager
    }

    @IBAction func undo(_ sender: Any?) {
        let focused = focusedUndoManager
        switch UndoRouting.target(
            responderCanAct: focused?.canUndo ?? false,
            appCanAct: undoManager.canUndo
        ) {
        case .firstResponder:
            focused?.undo()
        case .application:
            undoManager.undo()
        case .neither:
            break
        }
    }

    @IBAction func redo(_ sender: Any?) {
        let focused = focusedUndoManager
        switch UndoRouting.target(
            responderCanAct: focused?.canRedo ?? false,
            appCanAct: undoManager.canRedo
        ) {
        case .firstResponder:
            focused?.redo()
        case .application:
            undoManager.redo()
        case .neither:
            break
        }
    }

    private struct DerivedConfig {
        let initialWindow: Bool
        let shouldQuitAfterLastWindowClosed: Bool
        let quickTerminalPosition: QuickTerminalPosition

        init() {
            self.initialWindow = true
            self.shouldQuitAfterLastWindowClosed = false
            self.quickTerminalPosition = .top
        }

        init(_ config: Ghostty.Config) {
            self.initialWindow = config.initialWindow
            self.shouldQuitAfterLastWindowClosed = config.shouldQuitAfterLastWindowClosed
            self.quickTerminalPosition = config.quickTerminalPosition
        }
    }

    struct ToggleVisibilityState {
        let hiddenWindows: [Weak<NSWindow>]
        let keyWindow: Weak<NSWindow>?

        fileprivate init() {
            // We need to know the key window so that we can bring focus back to the
            // right window if it was hidden.
            self.keyWindow = if let keyWindow = NSApp.keyWindow {
                .init(keyWindow)
            } else {
                nil
            }

            // We need to keep track of the windows that were visible because we only
            // want to bring back these windows if we remove the toggle.
            //
            // We also ignore fullscreen windows because they don't hide anyways.
            var visibleWindows = [Weak<NSWindow>]()
            NSApp.windows.filter {
                $0.isVisible &&
                !$0.styleMask.contains(.fullScreen)
            }.forEach { window in
                // We only keep track of selectedWindow if it's in a tabGroup,
                // so we can keep its selection state when restoring
                let windowToHide = window.tabGroup?.selectedWindow ?? window
                if !visibleWindows.contains(where: { $0.value === windowToHide }) {
                    visibleWindows.append(Weak(windowToHide))
                }
            }
            self.hiddenWindows = visibleWindows
        }

        func restore() {
            hiddenWindows.forEach { $0.value?.orderFrontRegardless() }
            keyWindow?.value?.makeKey()
        }
    }
}

// MARK: Menu

extension AppDelegate {
    /// This is called for the dock right-click menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return dockMenu
    }

    private func reloadDockMenu() {
        let newWindow = NSMenuItem(title: "New Window", action: #selector(newWindow), keyEquivalent: "")
        let newTab = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "")

        dockMenu.removeAllItems()
        dockMenu.addItem(newWindow)
        dockMenu.addItem(newTab)
    }

    /// Setup all the images for our menu items.
    private func setupMenuImages() {
        // Note: This COULD Be done all in the xib file, but I find it easier to
        // modify this stuff as code.
        self.menuAbout?.setImageIfDesired(systemSymbolName: "info.circle")
        self.menuCheckForUpdates?.setImageIfDesired(systemSymbolName: "square.and.arrow.down")
        self.menuOpenConfig?.setImageIfDesired(systemSymbolName: "gear")
        self.menuReloadConfig?.setImageIfDesired(systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90")
        self.menuSecureInput?.setImageIfDesired(systemSymbolName: "lock.display")
        self.menuNewWindow?.setImageIfDesired(systemSymbolName: "macwindow.badge.plus")
        self.menuNewTab?.setImageIfDesired(systemSymbolName: "macwindow")
        self.menuSplitRight?.setImageIfDesired(systemSymbolName: "rectangle.righthalf.inset.filled")
        self.menuSplitLeft?.setImageIfDesired(systemSymbolName: "rectangle.leadinghalf.inset.filled")
        self.menuSplitUp?.setImageIfDesired(systemSymbolName: "rectangle.tophalf.inset.filled")
        self.menuSplitDown?.setImageIfDesired(systemSymbolName: "rectangle.bottomhalf.inset.filled")
        self.menuClose?.setImageIfDesired(systemSymbolName: "xmark")
        self.menuPasteSelection?.setImageIfDesired(systemSymbolName: "doc.on.clipboard.fill")
        self.menuIncreaseFontSize?.setImageIfDesired(systemSymbolName: "textformat.size.larger")
        self.menuResetFontSize?.setImageIfDesired(systemSymbolName: "textformat.size")
        self.menuDecreaseFontSize?.setImageIfDesired(systemSymbolName: "textformat.size.smaller")
        self.menuCommandPalette?.setImageIfDesired(systemSymbolName: "filemenu.and.selection")
        self.menuQuickTerminal?.setImageIfDesired(systemSymbolName: "apple.terminal")
        self.menuChangeTabTitle?.setImageIfDesired(systemSymbolName: "pencil.line")
        self.menuTerminalInspector?.setImageIfDesired(systemSymbolName: "scope")
        self.menuReadonly?.setImageIfDesired(systemSymbolName: "eye.fill")
        self.menuSetAsDefaultTerminal?.setImageIfDesired(systemSymbolName: "star.fill")
        self.menuToggleFullScreen?.setImageIfDesired(systemSymbolName: "square.arrowtriangle.4.outward")
        self.menuToggleVisibility?.setImageIfDesired(systemSymbolName: "eye")
        self.menuZoomSplit?.setImageIfDesired(systemSymbolName: "arrow.up.left.and.arrow.down.right")
        self.menuPreviousSplit?.setImageIfDesired(systemSymbolName: "chevron.backward.2")
        self.menuNextSplit?.setImageIfDesired(systemSymbolName: "chevron.forward.2")
        self.menuEqualizeSplits?.setImageIfDesired(systemSymbolName: "inset.filled.topleft.topright.bottomleft.bottomright.rectangle")
        self.menuSelectSplitLeft?.setImageIfDesired(systemSymbolName: "arrow.left")
        self.menuSelectSplitRight?.setImageIfDesired(systemSymbolName: "arrow.right")
        self.menuSelectSplitAbove?.setImageIfDesired(systemSymbolName: "arrow.up")
        self.menuSelectSplitBelow?.setImageIfDesired(systemSymbolName: "arrow.down")
        self.menuMoveSplitDividerUp?.setImageIfDesired(systemSymbolName: "arrow.up.to.line")
        self.menuMoveSplitDividerDown?.setImageIfDesired(systemSymbolName: "arrow.down.to.line")
        self.menuMoveSplitDividerLeft?.setImageIfDesired(systemSymbolName: "arrow.left.to.line")
        self.menuMoveSplitDividerRight?.setImageIfDesired(systemSymbolName: "arrow.right.to.line")
        self.menuFloatOnTop?.setImageIfDesired(systemSymbolName: "square.filled.on.square")
        self.menuFindParent?.setImageIfDesired(systemSymbolName: "text.page.badge.magnifyingglass")
    }

    /// Sync all of our menu item keyboard shortcuts with the Ghostty configuration.
    @MainActor private func syncMenuShortcuts(_ config: Ghostty.Config) {
        guard ghostty.readiness == .ready else { return }

        menuShortcutManager.reset()

        syncMenuShortcut(config, action: "check_for_updates", menuItem: self.menuCheckForUpdates)
        syncMenuShortcut(config, action: "open_config", menuItem: self.menuOpenConfig)
        syncMenuShortcut(config, action: "reload_config", menuItem: self.menuReloadConfig)
        syncMenuShortcut(config, action: "quit", menuItem: self.menuQuit)

        syncMenuShortcut(config, action: "new_window", menuItem: self.menuNewWindow)
        syncMenuShortcut(config, action: "new_tab", menuItem: self.menuNewTab)
        syncMenuShortcut(config, action: "close_surface", menuItem: self.menuClose)
        syncMenuShortcut(config, action: "close_tab", menuItem: self.menuCloseTab)
        syncMenuShortcut(config, action: "close_window", menuItem: self.menuCloseWindow)
        syncMenuShortcut(config, action: "close_all_windows", menuItem: self.menuCloseAllWindows)
        syncMenuShortcut(config, action: "new_split:right", menuItem: self.menuSplitRight)
        syncMenuShortcut(config, action: "new_split:left", menuItem: self.menuSplitLeft)
        syncMenuShortcut(config, action: "new_split:down", menuItem: self.menuSplitDown)
        syncMenuShortcut(config, action: "new_split:up", menuItem: self.menuSplitUp)

        /// These four keep a macOS-standard shortcut when the configuration
        /// has no answer for them — see
        /// `MenuShortcutManager.standardEditingShortcuts`.
        syncMenuShortcut(config, action: "undo", menuItem: self.menuUndo)
        syncMenuShortcut(config, action: "redo", menuItem: self.menuRedo)
        syncMenuShortcut(config, action: "copy_to_clipboard", menuItem: self.menuCopy)
        syncMenuShortcut(config, action: "paste_from_clipboard", menuItem: self.menuPaste)
        syncMenuShortcut(config, action: "paste_from_selection", menuItem: self.menuPasteSelection)
        syncMenuShortcut(config, action: "select_all", menuItem: self.menuSelectAll)
        syncMenuShortcut(config, action: "start_search", menuItem: self.menuFind)
        syncMenuShortcut(config, action: "end_search", menuItem: self.menuHideFindBar)
        syncMenuShortcut(config, action: "search_selection", menuItem: self.menuSelectionForFind)
        syncMenuShortcut(config, action: "scroll_to_selection", menuItem: self.menuScrollToSelection)
        syncMenuShortcut(config, action: "navigate_search:next", menuItem: self.menuFindNext)
        syncMenuShortcut(config, action: "navigate_search:previous", menuItem: self.menuFindPrevious)

        syncMenuShortcut(config, action: "toggle_split_zoom", menuItem: self.menuZoomSplit)
        syncMenuShortcut(config, action: "goto_split:previous", menuItem: self.menuPreviousSplit)
        syncMenuShortcut(config, action: "goto_split:next", menuItem: self.menuNextSplit)
        syncMenuShortcut(config, action: "goto_split:up", menuItem: self.menuSelectSplitAbove)
        syncMenuShortcut(config, action: "goto_split:down", menuItem: self.menuSelectSplitBelow)
        syncMenuShortcut(config, action: "goto_split:left", menuItem: self.menuSelectSplitLeft)
        syncMenuShortcut(config, action: "goto_split:right", menuItem: self.menuSelectSplitRight)
        syncMenuShortcut(config, action: "resize_split:up,10", menuItem: self.menuMoveSplitDividerUp)
        syncMenuShortcut(config, action: "resize_split:down,10", menuItem: self.menuMoveSplitDividerDown)
        syncMenuShortcut(config, action: "resize_split:right,10", menuItem: self.menuMoveSplitDividerRight)
        syncMenuShortcut(config, action: "resize_split:left,10", menuItem: self.menuMoveSplitDividerLeft)
        syncMenuShortcut(config, action: "equalize_splits", menuItem: self.menuEqualizeSplits)
        syncMenuShortcut(config, action: "reset_window_size", menuItem: self.menuReturnToDefaultSize)

        syncMenuShortcut(config, action: "increase_font_size:1", menuItem: self.menuIncreaseFontSize)
        syncMenuShortcut(config, action: "decrease_font_size:1", menuItem: self.menuDecreaseFontSize)
        syncMenuShortcut(config, action: "reset_font_size", menuItem: self.menuResetFontSize)
        syncMenuShortcut(config, action: "prompt_surface_title", menuItem: self.menuChangeTitle)
        syncMenuShortcut(config, action: "prompt_tab_title", menuItem: self.menuChangeTabTitle)
        syncMenuShortcut(config, action: "toggle_quick_terminal", menuItem: self.menuQuickTerminal)
        syncMenuShortcut(config, action: "toggle_visibility", menuItem: self.menuToggleVisibility)
        syncMenuShortcut(config, action: "toggle_window_float_on_top", menuItem: self.menuFloatOnTop)
        syncMenuShortcut(config, action: "inspector:toggle", menuItem: self.menuTerminalInspector)
        syncMenuShortcut(config, action: "toggle_command_palette", menuItem: self.menuCommandPalette)

        syncMenuShortcut(config, action: "toggle_secure_input", menuItem: self.menuSecureInput)

        // This menu item is NOT synced with the configuration because it disables macOS
        // global fullscreen keyboard shortcut. The shortcut in the Ghostty config will continue
        // to work but it won't be reflected in the menu item.
        //
        // syncMenuShortcut(config, action: "toggle_fullscreen", menuItem: self.menuToggleFullScreen)

        // Dock menu
        reloadDockMenu()
    }

    @MainActor private func syncMenuShortcut(_ config: Ghostty.Config, action: String, menuItem: NSMenuItem?) {
        menuShortcutManager.syncMenuShortcut(config, action: action, menuItem: menuItem)
    }

    @MainActor func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool {
        menuShortcutManager.performGhosttyBindingMenuKeyEquivalent(with: event)
    }
}

// MARK: Floating Windows

extension AppDelegate {
    func syncFloatOnTopMenu(_ window: NSWindow?) {
        guard let window = (window ?? NSApp.keyWindow) as? TerminalWindow else {
            // If some other window became key we always turn this off
            self.menuFloatOnTop?.state = .off
            return
        }

        self.menuFloatOnTop?.state = window.level == .floating ? .on : .off
    }

    @IBAction func floatOnTop(_ menuItem: NSMenuItem) {
        menuItem.state = menuItem.state == .on ? .off : .on
        guard let window = NSApp.keyWindow else { return }
        window.level = menuItem.state == .on ? .floating : .normal
    }

    @IBAction func useAsDefault(_ sender: NSMenuItem) {
        let ud = UserDefaults.ghostty
        let key = TerminalWindow.defaultLevelKey
        if menuFloatOnTop?.state == .on {
            ud.set(NSWindow.Level.floating, forKey: key)
        } else {
            ud.removeObject(forKey: key)
        }
    }

    @IBAction func setAsDefaultTerminal(_ sender: NSMenuItem) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .unixExecutable) { error in
            guard let error else { return }
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Failed to Set Default Terminal"
                alert.informativeText = """
                Ghostty could not be set as the default terminal application.

                Error: \(error.localizedDescription)
                """
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}

// MARK: NSMenuItemValidation

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setAsDefaultTerminal(_:)):
            return NSWorkspace.shared.defaultTerminal != Bundle.main.bundleURL

        case #selector(floatOnTop(_:)),
            #selector(useAsDefault(_:)):
            // Float on top items only active if the key window is a primary
            // terminal window (not quick terminal).
            return NSApp.keyWindow is TerminalWindow

        /// Validated through the same routing the action uses, and not
        /// separately, because the two disagreeing is its own bug: validate
        /// against one manager and act on another and you get a menu item
        /// that is enabled and does nothing, or greyed out over a stack that
        /// had something to undo.
        case #selector(undo(_:)):
            let focused = focusedUndoManager
            switch UndoRouting.target(
                responderCanAct: focused?.canUndo ?? false,
                appCanAct: undoManager.canUndo
            ) {
            case .firstResponder:
                item.title = UndoRouting.menuTitle(
                    verb: "Undo",
                    actionName: focused?.undoActionName ?? "")
                return true
            case .application:
                item.title = UndoRouting.menuTitle(
                    verb: "Undo",
                    actionName: undoManager.undoActionName)
                return true
            case .neither:
                item.title = "Undo"
                return false
            }

        case #selector(redo(_:)):
            let focused = focusedUndoManager
            switch UndoRouting.target(
                responderCanAct: focused?.canRedo ?? false,
                appCanAct: undoManager.canRedo
            ) {
            case .firstResponder:
                item.title = UndoRouting.menuTitle(
                    verb: "Redo",
                    actionName: focused?.redoActionName ?? "")
                return true
            case .application:
                item.title = UndoRouting.menuTitle(
                    verb: "Redo",
                    actionName: undoManager.redoActionName)
                return true
            case .neither:
                item.title = "Redo"
                return false
            }

        default:
            return true
        }
    }
}

// MARK: - Termination Flow

extension AppDelegate {
    func terminate() -> NSApplication.TerminateReply {
        let controllersNeedConfirmation = NSApplication.shared.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .filter { !$0.windowCanBeClosedWithoutConfirmation() }

        guard !controllersNeedConfirmation.isEmpty else {
            return .terminateNow
        }

        if controllersNeedConfirmation.count == 1 {
            Task {
                let response = await controllersNeedConfirmation[0].confirmCloseAsync(
                    messageText: "Quit \(appDisplayName)?",
                    informativeText: "The terminal still has a running process. If you quit, the process will be killed.",
                    confirmButtonTitle: "Terminate",
                )

                if [.OK, .alertFirstButtonReturn].contains(response) {
                    await NSApp.reply(toApplicationShouldTerminate: true)
                } else {
                    PhantomSessionStore.shared.quitWasCancelled()
                    await NSApp.reply(toApplicationShouldTerminate: false)
                }
            }

            return .terminateLater
        } else {
            let alert = NSAlert()
            alert.messageText = "You have \(controllersNeedConfirmation.count) windows with running processes. Do you want to review these windows before quitting?"
            alert.informativeText = "If you don't review your windows, any running processes will be terminated"
            alert.addButton(withTitle: "Review Windows...")
            alert.addButton(withTitle: "Terminate Processes")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                reviewWindows(controllersNeedConfirmation)
                return .terminateLater
            case .alertSecondButtonReturn:
                return .terminateNow
            default:
                PhantomSessionStore.shared.quitWasCancelled()
                return .terminateCancel
            }
        }
    }

    private func reviewWindows(_ controllers: [BaseTerminalController]) {
        Task {
            for controller in controllers {
                let response = await controller.confirmCloseAsync(
                    messageText: "Quit \(appDisplayName)?",
                    informativeText: "The terminal still has a running process. If you quit, the process will be killed.",
                    confirmButtonTitle: "Terminate",
                )

                if [.OK, .alertFirstButtonReturn].contains(response) {
                    // Close this window and until next review is cancelled
                    await controller.window?.close()
                    continue
                } else {
                    PhantomSessionStore.shared.quitWasCancelled()
                    await NSApp.reply(toApplicationShouldTerminate: false)
                    // Cancel the review
                    return
                }
            }
            await NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
}

/// Which undo manager Edit ▸ Undo and Edit ▸ Redo belong to.
///
/// There are two of them and they are not interchangeable. The app-level
/// `ExpiringUndoManager` undoes window operations — closing a tab, closing a
/// split — and a focused text view owns a separate stack holding the reader's
/// typing. The Undo menu item is wired to the First Responder in `MainMenu.xib`
/// and `AppDelegate` is the only object in the app that implements `undo:`, so
/// every ⌘Z in the app arrives here regardless of what has focus. Sending them
/// all to the app-level manager left the editor with an undo stack nothing
/// asked and a menu item greyed out over a buffer full of unsaved keystrokes.
///
/// Inherited rather than introduced: upstream Ghostty has no text editor, so
/// the app-level manager was the only thing ⌘Z could have meant. It became
/// wrong the day this fork grew an editor.
///
/// Spelled over booleans rather than over the managers themselves so the rule
/// can be exercised without a window, a menu or a responder chain — the same
/// reason `PhantomSessionStore` states its predicates this way. The action and
/// the menu validation must reach identical conclusions, and the only way to
/// hold them to that is for both to call this.
enum UndoRouting {
    /// The manager an Edit menu action should be sent to.
    enum Target: Equatable {
        /// The focused responder's own stack.
        case firstResponder
        /// The app-level stack: window operations, and the fallback whenever
        /// the responder has nothing of its own to give back.
        case application
        /// Neither has anything to undo, so the menu item is disabled.
        ///
        /// Named for what it means rather than `none`, which in a switch over
        /// this type reads like `Optional.none` to everyone but the compiler.
        case neither
    }

    /// The focused responder wins when it has something to undo; the app-level
    /// manager is the fallback.
    ///
    /// Deliberately not "whichever is non-nil": a terminal surface has no undo
    /// stack of its own, so the chain resolves it to the app-level manager and
    /// both arguments describe the same object. Choosing the responder there is
    /// the same act as choosing the app, which is why this needs no third
    /// question about whether the two are one.
    ///
    /// Used for redo as well — hence `canAct` rather than `canUndo`. The rule
    /// is about which stack is in front, and that does not change with the
    /// direction of travel.
    static func target(responderCanAct: Bool, appCanAct: Bool) -> Target {
        if responderCanAct { return .firstResponder }
        if appCanAct { return .application }
        return .neither
    }

    /// The menu item's title for the manager that is going to act.
    ///
    /// `undoActionName` is empty for a registration nobody named, and pasting
    /// an empty name onto the verb leaves "Undo " sitting in the menu with a
    /// trailing space. The bare verb is the honest title in that case.
    static func menuTitle(verb: String, actionName: String) -> String {
        actionName.isEmpty ? verb : "\(verb) \(actionName)"
    }
}

/// Represents the state of the quick terminal controller.
private enum QuickTerminalState {
    /// Controller has not been initialized and has no pending restoration state.
    case uninitialized
    /// Restoration state is pending; controller will use this when first accessed.
    case pendingRestore(QuickTerminalRestorableState)
    /// Controller has been initialized.
    case initialized(QuickTerminalController)
}
