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
///
/// The same files carry the agent and session id a restored tab resumes
/// with, which is why nothing here deletes one that still holds them.
@MainActor
final class TabStateCenter: ObservableObject {
    static let shared = TabStateCenter()

    @Published private(set) var states: [UUID: AgentTabState] = [:]

    /// The full parsed contents behind `states`, kept so that the writes this
    /// class makes back to a state file — consuming an attention marker,
    /// clearing a seen `done` — can put the agent and session id back rather
    /// than truncating the file to the one word they needed.
    private(set) var records: [UUID: AgentTabRecord] = [:]

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
        var parsed: [UUID: AgentTabRecord] = [:]
        for url in entries {
            guard let id = UUID(uuidString: url.lastPathComponent),
                  let raw = try? String(contentsOf: url, encoding: .utf8)
            else { continue }

            let record = AgentTabRecord(fileContents: raw)
            parsed[id] = record

            // The Notification hook's attention marker: fire the system
            // notification, then hand the file back to its previous state
            // so the marker is consumed exactly once.
            if record.stateWord == Self.notifyMarker {
                let restored = handleAttentionMarker(for: id, carrying: record)
                parsed[id] = restored
                if let previous = restored?.state { result[id] = previous }
                continue
            }

            guard let state = record.state else { continue }
            if state == .ended { continue }
            result[id] = state
        }

        notifyTransitions(from: states, to: result)
        records = parsed
        if result != states { states = result }
    }

    /// Clears a `done` marker once its tab has been seen (selected).
    ///
    /// The indicator goes, but the file only goes with it when there is
    /// nothing else in it. Deleting a file that still names the tab's agent
    /// and session would mean that glancing at a finished task costs you the
    /// ability to resume it after a restart — the single most likely moment
    /// for a tab to be both finished and worth coming back to. What is left
    /// is a stateless record: no word on the first line, so no indicator, and
    /// enough identity to come back.
    /// Records that a tab was started with an agent, before that agent has
    /// had a chance to say anything.
    ///
    /// Phantom starts these sessions itself, and until now it threw that
    /// away: whether a tab had an agent in it was known only from a file the
    /// *hook* writes. So a tab whose hook was not installed, or whose agent
    /// exited before reaching a hook event, left nothing behind — and a
    /// restore had no reason to believe there was ever a session there. It
    /// did not fail to resume; it never tried.
    ///
    /// Written with no state word, so it shows no indicator: this says which
    /// agent the tab is running, not what it is doing. Any id a hook captures
    /// later is merged on top, and an id already on record survives — being
    /// asked to start an agent in a tab that already has a conversation must
    /// not lose the conversation.
    func recordAgentStart(surfaceId: UUID, agent: CodingAgent) {
        let existing = records[surfaceId]
        let record = AgentTabRecord(
            stateWord: existing?.stateWord ?? "",
            agent: agent,
            sessionID: existing?.sessionID
        )

        let url = Self.stateFileURL(for: surfaceId)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? record.fileContents.write(to: url, atomically: true, encoding: .utf8)
        records[surfaceId] = record
    }

    func clearDone(surfaceId: UUID) {
        guard states[surfaceId] == .done else { return }
        let url = Self.stateFileURL(for: surfaceId)
        let record = records[surfaceId] ?? AgentTabRecord(stateWord: "")

        if record.carriesIdentity {
            let cleared = AgentTabRecord(
                stateWord: "",
                agent: record.agent,
                sessionID: record.sessionID
            )
            try? cleared.fileContents.write(to: url, atomically: true, encoding: .utf8)
            records[surfaceId] = cleared
        } else {
            try? FileManager.default.removeItem(at: url)
            records.removeValue(forKey: surfaceId)
        }
        states.removeValue(forKey: surfaceId)
    }

    /// Consumes the Notification hook's attention marker: posts a system
    /// notification for an unfocused tab, then hands the state file back to
    /// its previous state (or deletes it) so the marker fires exactly once.
    ///
    /// The identity written back is the *marker's*, not the one on record:
    /// the notifying write is the freshest word on which agent and session
    /// this tab is running, and rolling it back with the state would cost the
    /// tab its resume. Returns what was written, or nil if the file went.
    @discardableResult
    private func handleAttentionMarker(
        for surfaceId: UUID,
        carrying record: AgentTabRecord
    ) -> AgentTabRecord? {
        let info = tabInfo(for: surfaceId)
        if info?.isFocused != true {
            deliver(message: "Agent needs your attention", tabTitle: info?.title)
        }

        let url = Self.stateFileURL(for: surfaceId)
        let restored = AgentTabRecord(
            stateWord: states[surfaceId]?.rawValue ?? "",
            agent: record.agent,
            sessionID: record.sessionID
        )

        guard restored.state != nil || restored.carriesIdentity else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? restored.fileContents.write(to: url, atomically: true, encoding: .utf8)
        return restored
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
