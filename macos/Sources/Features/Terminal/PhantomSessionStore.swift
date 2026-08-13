import AppKit
import Foundation

/// Phantom's own terminal session persistence.
///
/// macOS window restoration is the app's nominal restore mechanism, but it
/// is famously unreliable: when windows are closed and reopened within a
/// session, macOS has been observed to restore only one or two of the
/// windows that were open at quit time, silently dropping the rest.
/// Ghostty upstream documents this as an unfixable macOS behavior and plans
/// to move to its own session persistence.
///
/// This store is that persistence. It mirrors every open terminal window
/// (surface trees, working directories, frames, tab colors, title
/// overrides) to a file and, on launch, restores from it instead of
/// trusting macOS's saved state. macOS's own restore is kept as the
/// bootstrap for the first launch after this lands: while the store is
/// empty, macOS restores as usual and the store simply records what ended
/// up open; once the store has a session, the macOS restore path stands
/// down and this store is authoritative.
final class PhantomSessionStore {
    static let shared = PhantomSessionStore()

    /// While restoring from the store, saves are suspended so a partial
    /// window set can never overwrite the saved session.
    private var isRestoring = false

    /// True when this process is a test host rather than the app someone is
    /// using.
    ///
    /// The tests run *inside* Phantom.app, so without this the suite plays
    /// the whole session lifecycle against the real file: launch restores
    /// the user's actual windows — spawning their shells, and resuming
    /// their agent sessions — and termination writes whatever the test host
    /// happened to have open back over it. A test run would quietly replace
    /// the session someone left behind.
    private static let isRunningTests: Bool = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    /// Membership changes arrive in bursts (a window close, a tab open, a
    /// macOS restore); only the final state matters.
    private static let saveDebounce: TimeInterval = 0.4

    private init() {
        fileURL = Self.defaultFileURL()
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "com.ipetinate.phantom",
                isDirectory: true
            )
            .appendingPathComponent("session.json")
    }

    // MARK: Saving

    /// Re-reads the open terminal windows and writes the session file,
    /// debounced. A single call per burst; cancelled work items never run.
    func scheduleSave() {
        guard !isRestoring, !Self.isRunningTests else { return }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    /// Synchronous, authoritative save. Used at termination and when the
    /// debounced save fires.
    func saveNow() {
        guard !isRestoring, !Self.isRunningTests else { return }

        // Windows sharing a tab group are tabs of one window; record the
        // group membership and in-group order so the restore can re-form
        // tabs instead of producing separate windows.
        var groupIDByTabGroup: [ObjectIdentifier: Int] = [:]
        var nextGroupID = 0

        let states = TerminalController.all.compactMap { controller -> TerminalRestorableState? in
            guard let window = controller.window else { return nil }

            var tabGroupID: Int?
            var tabIndex: Int?
            if let group = window.tabGroup, group.windows.count > 1 {
                let key = ObjectIdentifier(group)
                if let existing = groupIDByTabGroup[key] {
                    tabGroupID = existing
                } else {
                    tabGroupID = nextGroupID
                    groupIDByTabGroup[key] = nextGroupID
                    nextGroupID += 1
                }
                tabIndex = group.windows.firstIndex(of: window)
            }

            return TerminalRestorableState(
                from: controller,
                tabGroupID: tabGroupID,
                tabIndex: tabIndex)
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(states)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Ghostty.logger.error(
                "session save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: Restoring

    /// True when a non-empty session is on disk. `restoreWindow` consults
    /// this to stand macOS's own restore down in favor of ours.
    var hasSavedSession: Bool {
        guard let states = load() else { return false }
        return !states.isEmpty
    }

    /// Restores the saved session. No-op when macOS already produced
    /// windows (the store is empty on the first launch after this feature
    /// lands) or when the saved session is empty.
    ///
    /// Called once, at launch, before the app would otherwise open a
    /// default window.
    func restoreIfNeeded() {
        guard !isRestoring, !Self.isRunningTests else { return }

        // Respect the explicit "never restore" choice, matching the check
        // macOS restoration performs.
        guard (NSApplication.shared.delegate as? AppDelegate)?.ghostty.config.windowSaveState != "never" else {
            return
        }

        // If macOS already restored windows there is nothing for us to do,
        // and creating more would duplicate them.
        guard TerminalController.all.isEmpty else { return }

        guard let states = load(), !states.isEmpty else { return }
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }

        isRestoring = true
        defer {
            isRestoring = false
            scheduleSave()
        }

        // Windows that were tabs of one window carry the same `tabGroupID`.
        // Re-form those groups so the restore produces tabs, not a pile of
        // separate windows.
        var groupIndexByID: [Int: Int] = [:]
        var groups: [[TerminalRestorableState]] = []
        var standalones: [TerminalRestorableState] = []
        for state in states {
            if let id = state.tabGroupID {
                if let index = groupIndexByID[id] {
                    groups[index].append(state)
                } else {
                    groupIndexByID[id] = groups.count
                    groups.append([state])
                }
            } else {
                standalones.append(state)
            }
        }

        // Restore one tab group (or a standalone window) at a time.
        for group in groups {
            restoreWindows(in: group, appDelegate: appDelegate)
        }
        for state in standalones {
            restoreWindows(in: [state], appDelegate: appDelegate)
        }
    }

    /// Creates the controllers for the states of one window (a tab group's
    /// members or a standalone window) and joins them into a tab group.
    ///
    /// Tabs must join the group *before* any window is shown — AppKit
    /// refuses to re-group a window that is already on screen, which is
    /// what turned restored tabs into separate windows. The selected tab
    /// (first in `tabGroup.windows` order at save time) is the group's
    /// anchor and the only one brought to the front.
    private func restoreWindows(
        in group: [TerminalRestorableState],
        appDelegate: AppDelegate
    ) {
        let ordered = group.sorted { lhs, rhs in
            (lhs.tabIndex ?? .max) < (rhs.tabIndex ?? .max)
        }

        var anchor: TerminalController?
        var previous: TerminalController?
        var standaloneState: TerminalRestorableState?
        var restored: [TerminalController] = []
        for state in ordered {
            let controller = TerminalController.init(
                appDelegate.ghostty,
                withSurfaceTree: state.surfaceTree)
            guard let window = controller.window else { continue }

            if let tabColor = state.tabColor {
                (window as? TerminalWindow)?.tabColor = tabColor
            }
            controller.titleOverride = state.titleOverride

            if let focusedStr = state.focusedSurface {
                var foundView: Ghostty.SurfaceView?
                for view in controller.surfaceTree where view.id.uuidString == focusedStr {
                    foundView = view
                    break
                }
                if let view = foundView {
                    controller.focusedSurface = view
                    Self.restoreFocus(to: view, inWindow: window)
                }
            }

            // Only the selected (anchor) window carries the frame and
            // fullscreen state; hidden tabs share its geometry. A standalone
            // window defers both until it is on screen, where fullscreen
            // transitions work.
            if anchor == nil {
                if group.count == 1 {
                    standaloneState = state
                } else if let mode = state.effectiveFullscreenMode, mode != .native {
                    // A native-fullscreen window saves its fullscreen bounds
                    // as the frame; restoring those onto a windowed window
                    // produces a giant, broken-looking window.
                    if let frame = state.frame {
                        window.setFrame(frame, display: false)
                    }
                    controller.toggleFullscreen(mode: mode)
                }
            }

            if anchor == nil {
                anchor = controller
            } else if window.tabbingMode == .disallowed {
                // Tabbing is disabled for this window: it stands alone.
                window.orderFrontRegardless()
            } else {
                // Join the tab group while the window is still off screen,
                // mirroring how `newWindow` creates tabs.
                //
                // The result is checked rather than discarded: when AppKit
                // refuses the grouping, the window has been created and is
                // holding a live shell but is on no screen and in no tab
                // bar. Showing it loose is a visible degradation; dropping
                // it is a terminal that silently doesn't exist.
                let joined = previous?.window?
                    .addTabbedWindowSafely(window, ordered: .above) ?? false
                if !joined { window.orderFrontRegardless() }
            }
            previous = controller
            restored.append(controller)
        }

        // Each sidebar was built before its window had joined the group: a
        // controller (and its sidebar) exists a moment before the tab is
        // added, so every one of them populated a one-row list. Nothing
        // observes the group *forming*, so the correction used to arrive
        // incidentally, on the first click — which is what made the list
        // visibly rebuild from one row to N in front of the user. Telling
        // them once the group is complete is that missing signal.
        //
        // A turn later, because AppKit's tab group bookkeeping is not
        // consistent until the next runloop cycle.
        DispatchQueue.main.async {
            for controller in restored {
                controller.sidebarTabManager?.scheduleRefresh()
            }
        }

        // Bring only the selected tab forward; the rest are hidden tabs.
        guard let anchorWindow = anchor?.window else { return }

        if let standaloneState {
            // A standalone window must come back as its own window.
            // `TerminalWindow` flips tabbing to `.automatic` on the next
            // runloop turn (that is what lets tabs re-form), but macOS
            // auto-tabs windows that appear in quick succession — a burst of
            // restored standalone windows would merge into one tab group.
            // Lock tabbing down after that flip, and only then show the
            // window, so AppKit never gets the chance to group it. Frame and
            // fullscreen are applied here too, after the window is on screen.
            DispatchQueue.main.async {
                // Restored, not adopted: the lock lasts exactly as long as
                // the window is appearing. Leaving it on is worse than the
                // merge it prevents — `TerminalController.newTab` refuses to
                // make a tab in a `.disallowed` window, so every terminal
                // opened in a restored window afterwards came back as
                // another loose window, for the rest of the session. The
                // previous value is put back rather than `.automatic`
                // assumed, because a hidden-titlebar window disallows
                // tabbing on purpose and must keep doing so.
                let tabbingBeforeReveal = anchorWindow.tabbingMode
                anchorWindow.tabbingMode = .disallowed
                anchorWindow.orderFrontRegardless()

                if let frame = standaloneState.frame,
                   standaloneState.effectiveFullscreenMode != .native {
                    anchorWindow.setFrame(frame, display: false)
                }
                if let mode = standaloneState.effectiveFullscreenMode {
                    anchor?.toggleFullscreen(mode: mode)
                }

                DispatchQueue.main.async {
                    anchorWindow.tabbingMode = tabbingBeforeReveal
                }
            }
        } else {
            anchorWindow.orderFrontRegardless()
        }
    }

    /// Retries making the given surface the first responder until the
    /// restored window's SwiftUI content catches up. Mirrors the focus
    /// restoration in `TerminalWindowRestoration`.
    private static func restoreFocus(
        to view: Ghostty.SurfaceView,
        inWindow: NSWindow,
        attempts: Int = 0
    ) {
        let after: DispatchTime
        if attempts == 0 {
            after = .now()
        } else if attempts > 40 {
            return
        } else {
            after = .now() + .milliseconds(50)
        }

        DispatchQueue.main.asyncAfter(deadline: after) {
            guard let viewWindow = view.window else {
                restoreFocus(to: view, inWindow: inWindow, attempts: attempts + 1)
                return
            }
            guard viewWindow == inWindow else { return }
            inWindow.makeFirstResponder(view)
            if viewWindow.isMainWindow {
                viewWindow.orderFront(nil)
            }
        }
    }

    private func load() -> [TerminalRestorableState]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([TerminalRestorableState].self, from: data)
    }
}
