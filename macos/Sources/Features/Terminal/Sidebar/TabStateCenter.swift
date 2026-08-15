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
    ///
    /// Thirty days, matching `SidebarGroupStore.assignmentMaxAge` — the other
    /// per-surface record kept beside a tab, and the same question about how
    /// long a tab may sit untouched and still be a tab.
    ///
    /// Two days was the number, and it was measured against how long a *file*
    /// stays interesting rather than how long a *tab* does. A state file's
    /// modification date only moves when a hook writes, so an agent tab left
    /// idle across a long weekend, or any tab at all on a machine that was off
    /// for three days, aged out while still open. The next launch then found no
    /// file, `resumeCommand(forStateFileContents: nil)` returned nil, and the
    /// tab came back as a bare shell without so much as attempting the
    /// imprecise resume — a silent loss of exactly the conversations most worth
    /// coming back to. Sixty bytes per closed tab is not a cost worth that.
    ///
    /// Still bounded rather than kept forever, because `refresh()` reads every
    /// entry in this directory on each change to it: an unbounded directory
    /// makes every hook write cost more than the one before.
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// How long a half-finished write may sit before it counts as abandoned.
    ///
    /// These are never identity and nothing reads them — `refresh()` skips any
    /// name that does not parse as a UUID — but they are still listed on every
    /// change to this directory, so they are swept on their own horizon instead
    /// of waiting out `maxAge` alongside the records that matter. An hour,
    /// because no hook's write takes one: shorter risks deleting a fragment
    /// out from under a hook that is mid-rename, which costs that hook its
    /// write.
    private static let fragmentMaxAge: TimeInterval = 60 * 60

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

    /// Clears a `done` marker once its tab has been seen (selected).
    ///
    /// The indicator goes, but the file only goes with it when there is
    /// nothing else in it. Deleting a file that still names the tab's agent
    /// and session would mean that glancing at a finished task costs you the
    /// ability to resume it after a restart — the single most likely moment
    /// for a tab to be both finished and worth coming back to. What is left
    /// is a stateless record: no word on the first line, so no indicator, and
    /// enough identity to come back.
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

    /// Sweeps the directory: abandoned write fragments quickly, spent records
    /// slowly, and never a record the saved session still points at.
    private func pruneStale() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: Self.stateDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        let referenced = PhantomSessionStore.referencedSurfaceIDs
        let now = Date()
        for url in entries {
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? .distantPast
            if Self.shouldPrune(
                url, modified: modified, now: now, referencedSurfaceIDs: referenced
            ) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Whether one entry in the state directory has outlived its usefulness.
    ///
    /// Age is asked first and always, and reference only ever *spares*. That
    /// order is the whole contract, because `referencedSurfaceIDs` returns an
    /// empty set for a session file that is missing, unreadable, or written by
    /// a build newer than this one — and an empty set means "this tells you
    /// nothing", never "nothing is referenced". Read the other way round, the
    /// moment the saved session were in trouble would be the moment every
    /// session id got deleted, which is precisely when they are least
    /// replaceable. So emptiness degrades to the age horizon alone — exactly
    /// the behavior before the reference check existed — and can never widen
    /// what goes.
    ///
    /// What the reference buys, on top of age: a tab open long enough to go
    /// quiet still has its conversation when it comes back. A state file's
    /// modification date moves only when a hook writes, so an agent tab left
    /// idle for a month, or any tab at all on a machine that spent one
    /// switched off, used to age out while still being a tab — and the next
    /// launch, finding no file, came up as a bare shell without even
    /// attempting a resume. Being named in `session.json` is the honest answer
    /// to the question age was standing in for: this surface is about to be
    /// restored.
    ///
    /// A write fragment is exempt from all of that. It is never identity —
    /// nothing reads it and no session is named in it — so it answers to its
    /// own short horizon and is never spared by reference.
    static func shouldPrune(
        _ url: URL,
        modified: Date,
        now: Date,
        referencedSurfaceIDs: Set<UUID>
    ) -> Bool {
        if isWriteFragment(url) {
            return modified < now.addingTimeInterval(-fragmentMaxAge)
        }
        guard modified < now.addingTimeInterval(-maxAge) else { return false }
        guard let surfaceId = UUID(uuidString: url.lastPathComponent) else { return true }
        return !referencedSurfaceIDs.contains(surfaceId)
    }

    /// Whether an entry is a hook's half-finished write rather than a record.
    ///
    /// The hooks write to a name of their own and rename it into place, so one
    /// of these only survives when the hook was killed between the two steps —
    /// which is what quitting Phantom does to an agent mid-turn.
    static func isWriteFragment(_ url: URL) -> Bool {
        url.pathExtension == "tmp" && UUID(uuidString: url.lastPathComponent) == nil
    }
}
