import AppKit

/// Recovering a terminal window that exists but cannot be reached.
///
/// The state is real and was watched happen: a window restored at launch,
/// used for hours — a tab was created in it — and then found orphaned. Its
/// shells were alive and it appeared in Mission Control, but clicking it
/// there raised nothing, and clicking the Dock icon did nothing either. The
/// signature is a window that is *ordered in* (`isVisible` is true, which is
/// why Mission Control lists it and why the reopen handler defers to macOS)
/// but is pinned to a Space that no longer exists, so nothing macOS does can
/// bring it forward. What does work — measured, because it is how the reader
/// eventually recovered it by accident — is `makeKeyAndOrderFront`, which
/// pulls the window onto the current Space.
///
/// What creates the orphan in the first place is not yet known; this app's
/// `os_log` output is not queryable on this machine, so the transition has
/// never been observed. `WindowBreadcrumbs` exists to catch it the next time.
/// Until then, this turns the dead end into one Dock click.
enum WindowGhostRescue {
    /// Whether the app is in the state the rescue exists for, decided from
    /// values so it can be tested without a window.
    ///
    /// Every condition is necessary:
    /// - not while inactive: the check runs on a delay, and the reader may
    ///   have switched away — yanking a window forward under another app
    ///   would be worse than the ghost.
    /// - not when a terminal is key or on the active Space: then the Dock
    ///   click worked, or a healthy Space switch is what happened.
    /// - not when there is nothing reachable: an empty app is the reopen
    ///   handler's case (it opens a new window), not a rescue.
    static func shouldRescue(
        appIsActive: Bool,
        aTerminalIsKey: Bool,
        aTerminalIsOnTheActiveSpace: Bool,
        reachableTerminals: Int
    ) -> Bool {
        appIsActive
            && !aTerminalIsKey
            && !aTerminalIsOnTheActiveSpace
            && reachableTerminals > 0
    }

    /// How long macOS gets to do the right thing first.
    ///
    /// A healthy "focus one of them" — including one that switches Spaces —
    /// makes a terminal key well inside a second. Checking sooner risks
    /// firing mid Space-switch animation and dragging a healthy window off
    /// the Space the reader keeps it on; checking later just makes the
    /// rescue feel like nothing happened again.
    static let verificationDelay: TimeInterval = 1.0

    /// Called from the reopen handler when macOS was left to focus an
    /// existing window. Verifies, after the delay, that something actually
    /// came forward — and pulls a window onto the current Space when nothing
    /// did.
    @MainActor
    static func verifyReopenLandedSomewhere() {
        DispatchQueue.main.asyncAfter(deadline: .now() + verificationDelay) {
            let controllers = TerminalController.all
            let windows = controllers.compactMap(\.window)

            let decision = shouldRescue(
                appIsActive: NSApp.isActive,
                aTerminalIsKey: windows.contains { $0.isKeyWindow },
                aTerminalIsOnTheActiveSpace: windows.contains {
                    $0.isOnActiveSpace && $0.isVisible
                },
                reachableTerminals: controllers.count { PhantomSessionStore.isReachable($0.window) }
            )

            guard decision else { return }
            guard let window = controllers.first(
                where: { PhantomSessionStore.isReachable($0.window) })?.window
            else { return }

            WindowBreadcrumbs.note(
                "rescue: reopen left no terminal reachable, ordering front " +
                "window=\(window.windowNumber) visible=\(window.isVisible) " +
                "onActiveSpace=\(window.isOnActiveSpace)")
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// A file of timestamped one-liners about window lifecycle, for the bug that
/// cannot be caught red-handed any other way.
///
/// `os_log` would be the right tool, and it does not work here: `log show`
/// returns nothing for this process — not even AppKit's own messages — which
/// has already cost one investigation its evidence. A file in Application
/// Support survives the app, can be read after the ghost is noticed hours
/// later, and costs one line of I/O per event on events that happen a handful
/// of times per session.
///
/// Development builds only. The file answers a developer's question, and
/// writing a log nobody will read into every user's disk is not a feature.
enum WindowBreadcrumbs {
    static func note(_ event: String) {
        guard DevelopmentBuild.isActive else { return }
        queue.async { append(event) }
    }

    /// Watches the moments a window can become an orphan, app-wide: Space
    /// and screen changes, fullscreen transitions, ordering. Registered once
    /// with nil objects, so every window is covered including ones created
    /// later.
    @MainActor
    static func startWatching() {
        guard DevelopmentBuild.isActive, observers.isEmpty else { return }

        let center = NotificationCenter.default
        let watched: [(Notification.Name, String)] = [
            (NSWindow.didEnterFullScreenNotification, "didEnterFullScreen"),
            (NSWindow.didExitFullScreenNotification, "didExitFullScreen"),
            (NSWindow.willCloseNotification, "willClose"),
            (NSWindow.didMiniaturizeNotification, "didMiniaturize"),
            (NSWindow.didDeminiaturizeNotification, "didDeminiaturize"),
            (NSWindow.didChangeScreenNotification, "didChangeScreen"),
            (NSWindow.didChangeOcclusionStateNotification, "didChangeOcclusionState"),
        ]

        for (name, label) in watched {
            observers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { notification in
                guard let window = notification.object as? NSWindow,
                      window.windowController is TerminalController
                else { return }
                note(
                    "\(label): window=\(window.windowNumber) " +
                    "visible=\(window.isVisible) " +
                    "onActiveSpace=\(window.isOnActiveSpace) " +
                    "miniaturized=\(window.isMiniaturized) " +
                    "occluded=\(!window.occlusionState.contains(.visible))")
            })
        }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            let summary = TerminalController.all.compactMap(\.window).map {
                "\($0.windowNumber):\($0.isOnActiveSpace ? "on" : "off")"
            }.joined(separator: " ")
            note("activeSpaceDidChange: \(summary)")
        })
    }

    private static var observers: [NSObjectProtocol] = []
    private static let queue = DispatchQueue(label: "window-breadcrumbs", qos: .utility)

    private static let url: URL? = {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first,
            let bundle = Bundle.main.bundleIdentifier
        else { return nil }
        let directory = support.appendingPathComponent(bundle, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("window-log.txt")
    }()

    private static func append(_ event: String) {
        guard let url else { return }
        rotateIfHuge(url)

        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(event)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// One rollover file, so a season of breadcrumbs cannot quietly eat the
    /// disk while still keeping the events leading up to whatever happened.
    private static func rotateIfHuge(_ url: URL) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 1_000_000 else { return }
        let old = url.deletingPathExtension().appendingPathExtension("old.txt")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
