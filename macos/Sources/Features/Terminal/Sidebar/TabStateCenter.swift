import AppKit
import Combine
import Foundation
import UserNotifications

/// Externally-reported state of the agent running in a tab.
enum AgentTabState: String {
    /// The agent is processing (spinner).
    case working

    /// The agent is waiting for user input.
    case awaiting

    /// The agent finished and produced output (attention until the tab
    /// is selected).
    case done

    /// The agent turn ended in an API error (red triangle).
    case failed

    /// A tool use was denied (orange stop sign).
    case denied

    /// The agent session ended cleanly; shows nothing, but the file's
    /// presence tells session restore not to resume it.
    case ended
}

/// Watches the tab-state directory that terminal-side tools write into.
///
/// Each surface exports `GHOSTTY_TAB_STATE_FILE` pointing at a file named
/// after its UUID inside this directory. External hooks (e.g. Claude Code
/// hooks) write `working` / `awaiting` / `done` into that file atomically
/// (write to a temp name, then `mv`), and the sidebar reflects it live.
@MainActor
final class TabStateCenter: ObservableObject {
    static let shared = TabStateCenter()

    @Published private(set) var states: [UUID: AgentTabState] = [:]

    static let stateDir: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".cache", isDirectory: true)
        .appendingPathComponent("phantom", isDirectory: true)
        .appendingPathComponent("tab-states", isDirectory: true)

    static func stateFileURL(for surfaceId: UUID) -> URL {
        stateDir.appendingPathComponent(surfaceId.uuidString)
    }

    /// Written by the Claude `Notification` hook: a transient "the agent
    /// wants your attention" marker. Not an agent state itself — it fires
    /// a system notification when the tab is unfocused, then restores the
    /// previous state (or removes the file) so it doesn't re-fire on the
    /// next directory refresh.
    static let notifyMarker = "notify"

    /// State files older than this are stale leftovers from closed tabs.
    private static let maxAge: TimeInterval = 2 * 24 * 60 * 60

    private var source: DispatchSourceFileSystemObject?

    init() {
        try? FileManager.default.createDirectory(
            at: Self.stateDir,
            withIntermediateDirectories: true
        )
        pruneStale()
        watch()
        refresh()
    }

    deinit {
        source?.cancel()
    }

    private func watch() {
        let fd = open(Self.stateDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func refresh() {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: Self.stateDir,
            includingPropertiesForKeys: nil
        )) ?? []

        var result: [UUID: AgentTabState] = [:]
        for url in entries {
            guard let id = UUID(uuidString: url.lastPathComponent),
                  let raw = try? String(contentsOf: url, encoding: .utf8)
            else { continue }

            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            // The Notification hook's attention marker: fire the system
            // notification, then hand the file back to its previous state
            // so the marker is consumed exactly once.
            if trimmed == Self.notifyMarker {
                handleAttentionMarker(for: id)
                if let previous = states[id] {
                    result[id] = previous
                }
                continue
            }

            guard let state = AgentTabState(rawValue: trimmed) else { continue }
            if state == .ended { continue }
            result[id] = state
        }

        notifyTransitions(from: states, to: result)
        if result != states { states = result }
    }

    /// Clears a `done` marker once its tab has been seen (selected).
    func clearDone(surfaceId: UUID) {
        guard states[surfaceId] == .done else { return }
        try? FileManager.default.removeItem(at: Self.stateFileURL(for: surfaceId))
        states.removeValue(forKey: surfaceId)
    }

    /// Consumes the Notification hook's attention marker: posts a system
    /// notification for an unfocused tab, then hands the state file back to
    /// its previous contents (or deletes it) so the marker fires exactly once.
    private func handleAttentionMarker(for surfaceId: UUID) {
        let info = tabInfo(for: surfaceId)
        if info?.isFocused != true {
            deliver(message: "Agent needs your attention", tabTitle: info?.title)
        }

        let url = Self.stateFileURL(for: surfaceId)
        if let previous = states[surfaceId] {
            try? previous.rawValue.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Posts a system notification when an unfocused tab's agent needs
    /// input or finishes, mirroring the in-sidebar indicators. A tab that
    /// is open and focused never notifies.
    private func notifyTransitions(
        from old: [UUID: AgentTabState],
        to new: [UUID: AgentTabState]
    ) {
        let enabled = UserDefaults.standard.object(
            forKey: "AgentNotificationsEnabled"
        ) as? Bool ?? true
        guard enabled else { return }

        for (id, state) in new {
            guard old[id] != state else { continue }

            let message: String
            switch state {
            case .done: message = "Task complete"
            case .failed: message = "Task failed"
            case .denied: message = "Action denied"
            case .awaiting: message = "Waiting for your input"
            default: continue
            }

            let info = tabInfo(for: id)
            if info?.isFocused == true { continue }
            deliver(message: message, tabTitle: info?.title)
        }
    }

    /// Finds the tab whose surface exported the given state file. `isFocused`
    /// reads the live window state (not the model's cached `isSelected`), so
    /// a state write racing with the window becoming key is not miscounted.
    private func tabInfo(for surfaceId: UUID) -> (title: String, isFocused: Bool)? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? TerminalController,
                  let model = controller.sidebarTabManager?.models
                    .first(where: { $0.surfaceId == surfaceId })
            else { continue }
            let focused = window.isKeyWindow
                || window.tabGroup?.selectedWindow == window
            return (model.title, focused)
        }
        return nil
    }

    private var didRequestNotificationAuth = false

    private func deliver(message: String, tabTitle: String?) {
        let center = UNUserNotificationCenter.current()

        let fire = {
            let content = UNMutableNotificationContent()
            content.title = "Agent Activity"
            if let tabTitle, !tabTitle.isEmpty {
                content.body = "\(message) \u{2014} \(tabTitle)"
            } else {
                content.body = message
            }
            content.sound = nil
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        }

        if didRequestNotificationAuth {
            fire()
        } else {
            didRequestNotificationAuth = true
            center.requestAuthorization(options: [.alert]) { granted, _ in
                if granted { DispatchQueue.main.async { fire() } }
            }
        }
    }

    private func pruneStale() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: Self.stateDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        for url in entries {
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
