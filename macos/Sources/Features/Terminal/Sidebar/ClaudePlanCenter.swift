import AppKit
import Combine

/// The Claude Code plans on disk, and which project each belongs to.
///
/// App-wide rather than per window: the plans directory is one directory, and
/// watching it once is cheaper than once per window. Which *terminals* show a
/// tag is decided per row, by asking whether its working directory is inside
/// the plan's project.
///
/// The attribution is to a **project**, not to a terminal. That is what the
/// data supports — see `ClaudePlanIndex` — so three tabs in the same repo all
/// show the tag. It is also true to what a plan is: it belongs to the work,
/// not to the window that happened to be focused.
@MainActor
final class ClaudePlanCenter: ObservableObject {
    static let shared = ClaudePlanCenter()

    /// The newest plan per encoded project.
    ///
    /// Only the newest: a project accumulates plans, and a row can show one
    /// tag. The one being worked on is the one just written.
    @Published private(set) var latestByProject: [String: ClaudePlanIndex.Plan] = [:]

    /// The plans the reader has hidden, kept here so a hide reaches every row
    /// at once — the tag is on as many rows as the project has terminals.
    @Published private(set) var hiddenPlans: Set<String> = []

    private let hideStore = ClaudePlanHideStore()

    private var watcher: DirectoryWatcher?
    private var isScanning = false

    private init() {
        hiddenPlans = Set(hideStore.hidden)
        start()
    }

    private func start() {
        let watcher = DirectoryWatcher()
        watcher.onChange = { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
        watcher.watch([ClaudePlanIndex.plansDirectory])
        self.watcher = watcher

        rescan()
    }

    /// The plan to offer a terminal sitting at `workingDirectory`.
    func plan(forTerminalAt workingDirectory: String?) -> ClaudePlanIndex.Plan? {
        ClaudePlanIndex.plan(
            forTerminalAt: workingDirectory,
            in: latestByProject,
            hidden: hiddenPlans
        )
    }

    /// Stops offering `plan` anywhere, leaving its file alone.
    func hide(_ plan: ClaudePlanIndex.Plan) {
        hideStore.hide(plan.path)
        hiddenPlans = Set(hideStore.hidden)
    }

    /// Removes the plan's file, and with it any record of it being hidden.
    ///
    /// The tag is dropped here as well as by the rescan the directory watcher
    /// is about to order, because that rescan re-reads session transcripts
    /// and takes as long as that takes. A reader who answered a confirmation
    /// about a file in their home directory should not then watch the tag sit
    /// there.
    func delete(_ plan: ClaudePlanIndex.Plan) {
        try? FileManager.default.removeItem(atPath: plan.path)
        hideStore.forget(plan.path)
        hiddenPlans = Set(hideStore.hidden)
        latestByProject = latestByProject.filter { $0.value.path != plan.path }
        rescan()
    }

    /// Reads the directory and resolves each plan's project.
    ///
    /// Off the main thread: resolving means reading the tail of transcripts,
    /// which are large. Guarded against overlap because a burst of writes to
    /// the plans directory is one scan's worth of news, not several.
    private func rescan() {
        guard !isScanning else { return }
        isScanning = true

        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) {
                let plans = ClaudePlanIndex.plans()

                var byProject: [String: ClaudePlanIndex.Plan] = [:]
                for plan in plans {
                    guard let project = ClaudePlanIndex.encodedProject(for: plan) else { continue }
                    // Newest first from `plans()`, so the first one wins.
                    if byProject[project] == nil { byProject[project] = plan }
                }
                return Scan(paths: Set(plans.map(\.path)), byProject: byProject)
            }.value

            await MainActor.run {
                guard let self else { return }
                self.isScanning = false
                if self.latestByProject != scan.byProject {
                    self.latestByProject = scan.byProject
                }
                self.pruneHidden(existing: scan.paths)
            }
        }
    }

    /// One scan's news: every plan file on disk, and the newest per project.
    ///
    /// Both, because the hide records are pruned against the whole directory
    /// and not against the projects — a plan that is not its project's newest
    /// is still a file that exists.
    private struct Scan {
        let paths: Set<String>
        let byProject: [String: ClaudePlanIndex.Plan]
    }

    /// Drops the hide records whose plan has left the directory.
    ///
    /// Here rather than on a timer, because this is the moment the directory
    /// has just been read — whether the plan went through Delete Plan, the
    /// Finder, or a `rm` in one of the terminals this sidebar lists.
    private func pruneHidden(existing: Set<String>) {
        hideStore.prune(existing: existing)
        let stored = Set(hideStore.hidden)
        if hiddenPlans != stored { hiddenPlans = stored }
    }
}
