import AppKit
import Combine

/// Observes the native tab group of a window and maintains one
/// `SidebarTabModel` per tab.
///
/// The published `models` array changes only when tabs are added,
/// removed or natively reordered; everything else (title, pwd, git,
/// selection, agent state) mutates the affected model in place so only
/// its row re-renders. `groupingVersion` bumps when group membership
/// inputs (pwd, surface id) change, signalling the view to re-resolve
/// sections without rebuilding rows.
@MainActor
final class SidebarTabManager: ObservableObject {
    @Published private(set) var models: [SidebarTabModel] = []
    @Published private(set) var groupingVersion = 0

    /// List animations stay off until the sidebar has seen its complete
    /// group and that group has been rendered once. A fresh or restored
    /// window's sidebar first sees only itself, then the whole group a
    /// moment later — animating that burst unfolds the entire list, and a
    /// restored window catches up on first click. The reveal is never
    /// animated; animations turn on from the second full-group pass on.
    @Published private(set) var animationsEnabled = false

    private weak var window: NSWindow?

    /// A newly created tab's window renders its sidebar before AppKit
    /// adds it to the tab group; until then, the parent group (the key
    /// window's at creation time) seeds the list so the sidebar never
    /// flashes empty.
    ///
    /// Only ever set when `shouldSeed` allows it — see there for why a
    /// window `PhantomSessionStore` is restoring must never get one.
    private weak var seedTabGroup: NSWindowTabGroup?

    private var modelsById: [ObjectIdentifier: SidebarTabModel] = [:]
    private var notificationObservers: [NSObjectProtocol] = []
    private var centerCancellables: Set<AnyCancellable> = []
    private var attentionWindows: Set<ObjectIdentifier> = []
    private var pendingRefresh = false
    private var didInitialPopulation = false

    /// Becomes true the first time a refresh sees the whole tab group at
    /// once, which is the moment a fresh or restored sidebar's list
    /// settles. Animations wait until the *second* full-group pass so the
    /// settle itself renders without unfolding the list.
    private var hasSeenFullGroup = false

    /// Some metadata changes with no pwd/title event to observe — `git
    /// checkout`, or a dev server starting — so a slow timer keeps it fresh.
    private var metadataRefreshTimer: Timer?

    init(window: NSWindow) {
        self.window = window

        if Self.shouldSeed(isRestoringSession: PhantomSessionStore.shared.isRestoring),
           let keyWindow = NSApp.keyWindow as? TerminalWindow,
           keyWindow !== window,
           let parentGroup = keyWindow.tabGroup {
            self.seedTabGroup = parentGroup
        }

        setupObservers()
        subscribeCenters()
        refresh()
        didInitialPopulation = true

        metadataRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: 5,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMetadata() }
        }
    }

    deinit {
        metadataRefreshTimer?.invalidate()
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Whether a just-initializing window may seed its sidebar from
    /// whichever window is currently key.
    ///
    /// True for the case the seed exists to serve: a genuinely new tab,
    /// created (say, by Cmd-T) while some other window is key, is about to
    /// join *that* window's group — `addTabbedWindowSafely` runs moments
    /// later, and the seed only bridges the gap until `own.tabGroup.windows
    /// .count > 1` becomes true and clears it itself.
    ///
    /// False during `PhantomSessionStore` restore, where the premise
    /// breaks: a restored window's group membership is decided entirely by
    /// the states in `session.json`, not by whatever happens to be key at
    /// the instant it is created, and a state that decoded with no
    /// `tabGroupID` is deliberately kept standalone — `tabbingMode` is
    /// forced `.disallowed` specifically so it never joins anything.
    /// `own.tabGroup.windows.count` can therefore never exceed 1 for that
    /// window, so the self-correction the seed relies on never fires, and
    /// the wrong group — some *other*, unrelated restored window's, borrowed
    /// only because it happened to be shown a moment earlier — would sit in
    /// `seedTabGroup` for as long as the window stays open. Its sidebar
    /// would go on listing tabs that live in somebody else's window, and
    /// selecting or closing one of those rows would act on that window
    /// instead of this one.
    static func shouldSeed(isRestoringSession: Bool) -> Bool {
        !isRestoringSession
    }

    /// All windows participating in this sidebar: our tab group once
    /// joined, else the seed (parent) group plus ourselves, else just us.
    ///
    /// Every answer is filtered to windows that are still open. AppKit keeps
    /// a closed window alive for as long as something holds its controller —
    /// which, with an agent running in it, is exactly what happens — and both
    /// sources here will go on handing those windows back: a closed window
    /// can still be listed by the tab group it belonged to, and `seedTabGroup`
    /// holds another window's group outright. A row built from one of those is
    /// a tab that no longer exists, drawn in a window that never owned it, and
    /// acting on it re-shows the corpse. See `select`, and
    /// `PhantomSessionStore.isOpen` for the predicate and what it had to learn.
    private var groupWindows: [NSWindow] {
        guard let window else { return [] }

        if let own = window.tabGroup?.windows, own.count > 1 {
            seedTabGroup = nil
            return Self.rowWindows(in: own, own: window)
        }

        if let seeded = seedTabGroup?.windows, !seeded.isEmpty {
            let live = Self.rowWindows(in: seeded, own: window)
            return live.contains(window) ? live : live + [window]
        }

        return Self.rowWindows(in: window.tabGroup?.windows ?? [window], own: window)
    }

    /// The windows in a group this sidebar may draw a row for.
    ///
    /// The sidebar's own window is always one of them, whatever the predicate
    /// says: it is the window the list is drawn in, and during initialization
    /// it is not on screen yet, so asking whether it is open answers no about
    /// a window that plainly exists — and the sidebar would populate empty.
    ///
    /// Every other window has to still be open. See `groupWindows` for why
    /// closed ones keep turning up here, and `select` for what a row built
    /// from one of them does when it is clicked.
    static func rowWindows(in group: [NSWindow], own: NSWindow) -> [NSWindow] {
        group.filter { $0 === own || isLiveTab($0) }
    }

    /// Whether a window is a tab a row may stand for and act on.
    ///
    /// Two terms, and the second is the one the window cannot answer: a husk
    /// that has been shown again reports `isVisible` like anything else, so
    /// only its controller knows it was closed. See
    /// `BaseTerminalController.hasClosed`.
    static func isLiveTab(_ window: NSWindow) -> Bool {
        guard (window.windowController as? BaseTerminalController)?.hasClosed != true
        else { return false }
        return PhantomSessionStore.isOpen(window)
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        let refreshNames: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ]
        for name in refreshNames {
            notificationObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }

        notificationObservers.append(center.addObserver(
            forName: .terminalWindowBellDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let controller = notification.object as? BaseTerminalController,
                      let bellWindow = controller.window
                else { return }

                let hasBell = notification.userInfo?[
                    Notification.Name.terminalWindowHasBellKey
                ] as? Bool ?? false

                let identifier = ObjectIdentifier(bellWindow)
                if hasBell, bellWindow != NSApp.keyWindow {
                    self.attentionWindows.insert(identifier)
                } else {
                    self.attentionWindows.remove(identifier)
                }
                self.modelsById[identifier]?.setNeedsAttention(
                    self.attentionWindows.contains(identifier)
                )
            }
        })
    }

    /// Shared centers are observed once here and distributed into the
    /// affected models, so rows never observe app-wide state.
    private func subscribeCenters() {
        TabStateCenter.shared.$states
            .sink { [weak self] states in
                guard let self else { return }
                for model in self.models {
                    guard let surfaceId = model.surfaceId else { continue }
                    model.setAgentState(states[surfaceId])
                }
            }
            .store(in: &centerCancellables)

        /// A second subscription rather than one on `$records` alone, because
        /// the two carry different news: `states` is what the agent is doing,
        /// records are whether there is a session at all. A row showing
        /// something about the session — the plan tag — goes quiet the moment
        /// that session ends, and `states` has never been able to report an
        /// ending: it drops `ended` on the floor.
        TabStateCenter.shared.$records
            .sink { [weak self] records in
                guard let self else { return }
                for model in self.models {
                    guard let surfaceId = model.surfaceId else { continue }
                    model.setLiveAgent(records[surfaceId]?.liveAgent)
                }
            }
            .store(in: &centerCancellables)

        GitStatusCenter.shared.$repos
            .sink { [weak self] repos in
                guard let self else { return }
                for model in self.models {
                    guard let root = model.repoRoot, let info = repos[root] else {
                        model.setRepoStatus(isDirty: nil, prNumber: nil, prURL: nil)
                        continue
                    }
                    model.setRepoStatus(
                        isDirty: info.isDirty,
                        prNumber: info.prNumber,
                        prURL: info.prURL
                    )
                }
            }
            .store(in: &centerCancellables)

        DevServerCenter.shared.$servers
            .sink { [weak self] servers in
                guard let self else { return }
                for model in self.models {
                    guard let pid = model.foregroundPID else {
                        model.setDevServerPort(nil)
                        continue
                    }
                    model.setDevServerPort(servers[pid]?.port)
                }
            }
            .store(in: &centerCancellables)
    }

    /// Only the selected tab's sidebar is on screen; hidden ones skip
    /// work entirely and catch up when their window is revealed (its
    /// didBecomeKey notification lands here as a scheduleRefresh).
    private var isSidebarVisible: Bool {
        guard let window else { return false }
        guard let group = window.tabGroup, group.windows.count > 1 else {
            return true
        }
        return group.selectedWindow == window
    }

    /// Coalesces bursts of notifications into a single pass per runloop turn.
    ///
    /// Deliberately **not** gated on the sidebar being visible, unlike the
    /// metadata pass below. A hidden tab's sidebar still has to be *correct*
    /// when it appears: skipping the reconciliation while hidden is what let
    /// a background tab sit on a one-row list until the moment it was
    /// selected, and then catch up all at once — the list visibly unfolding
    /// from one row to the whole group, in front of whoever just clicked it.
    /// Reconciling costs a walk over the group's windows and only reassigns
    /// `models` when membership actually changed, so paying it for a hidden
    /// tab is cheap; being wrong when it is shown is not.
    func scheduleRefresh() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRefresh = false
            self.refresh()
        }
    }

    /// Reconciles models against the native tab group: updates existing
    /// models in place, creates models for new tabs, drops closed ones.
    /// The published array is only reassigned when membership or native
    /// order actually changed.
    func refresh() {
        let windows = groupWindows
        var seen = Set<ObjectIdentifier>()

        for tabWindow in windows {
            guard let controller = tabWindow.windowController as? BaseTerminalController
            else { continue }

            let identifier = ObjectIdentifier(tabWindow)
            seen.insert(identifier)

            let model: SidebarTabModel
            /// Keyed by `ObjectIdentifier`, which is the window's address, so
            /// a window freed and a new one allocated in its place answer to
            /// the same key. The stored model would then be reused for a
            /// different window while still pointing at the old one, and every
            /// row action would land on whatever that address is now. Cheap to
            /// rule out, and impossible to debug once it happens.
            if let existing = modelsById[identifier], existing.window === tabWindow {
                model = existing
            } else {
                model = SidebarTabModel(window: tabWindow)
                modelsById[identifier] = model
                if didInitialPopulation {
                    registerNewTab(model, controller: controller)
                }
            }

            update(model, window: tabWindow, controller: controller)
        }

        for (identifier, _) in modelsById where !seen.contains(identifier) {
            modelsById.removeValue(forKey: identifier)
            attentionWindows.remove(identifier)
        }

        let ordered = windows.compactMap { modelsById[ObjectIdentifier($0)] }
        if ordered.map(\.id) != models.map(\.id) {
            models = ordered
        }

        // The list has settled once every window it knows about has a row.
        // Deliberately not `windows.count > 1`: a window that is not in a
        // tab group reports a group of one, so that spelling never became
        // true and its sidebar animated nothing for the rest of the session
        // — a whole class of user (one window, several splits, no tabs) lost
        // the animations entirely. What the burst needed protecting from was
        // the *first* settle, not the absence of tabs.
        if ordered.count == windows.count {
            if hasSeenFullGroup {
                animationsEnabled = true
            } else {
                hasSeenFullGroup = true
            }
        }
    }

    private func update(
        _ model: SidebarTabModel,
        window tabWindow: NSWindow,
        controller: BaseTerminalController
    ) {
        let surface = controller.focusedSurface
            ?? controller.surfaceTree.root?.leftmostLeaf()

        model.setTitle(tabWindow.title)
        model.setSelected(
            tabWindow.isKeyWindow || (tabWindow.tabGroup?.selectedWindow == tabWindow)
        )
        if model.isSelected {
            attentionWindows.remove(model.id)
        }
        model.setNeedsAttention(attentionWindows.contains(model.id))

        if model.surfaceId != surface?.id {
            model.setSurfaceId(surface?.id)
            if let surfaceId = surface?.id {
                model.setAgentState(TabStateCenter.shared.states[surfaceId])
                model.setLiveAgent(TabStateCenter.shared.records[surfaceId]?.liveAgent)
            } else {
                model.setAgentState(nil)
                model.setLiveAgent(nil)
            }
            bumpGrouping()
        }

        applyPwd(surface?.pwd, to: model)
        applyDevServer(surface, to: model)
        subscribe(model, to: surface)
    }

    /// The foreground PID changes every time a command starts or stops, so
    /// it is re-read on each pass and the scan is asked for again — the
    /// center coalesces that into one system-wide scan per TTL window.
    private func applyDevServer(
        _ surface: Ghostty.SurfaceView?,
        to model: SidebarTabModel
    ) {
        guard let pid = surface?.surfaceModel?.foregroundPID else {
            model.setForegroundPID(nil)
            model.setDevServerPort(nil)
            return
        }

        model.setForegroundPID(pid)
        model.setDevServerPort(DevServerCenter.shared.port(forPID: pid))
        DevServerCenter.shared.requestRefresh(pid: pid)
    }

    private func applyPwd(_ pwd: String?, to model: SidebarTabModel) {
        guard model.pwd != pwd else { return }
        model.setPwd(pwd)
        bumpGrouping()

        let git = Self.gitInfo(for: pwd)
        model.setGit(branch: git?.branch, root: git?.root)
        model.setInManagedWorktree(
            GitWorktreeMembership.contains(pwd: pwd, root: WorktreeSettings.managedRoot),
            repo: Self.worktreeRepo(forRepoRoot: git?.root, pwd: pwd))
        if let git {
            GitStatusCenter.shared.requestRefresh(root: git.root, branch: git.branch)
            let info = GitStatusCenter.shared.info(forRoot: git.root)
            model.setRepoStatus(
                isDirty: info?.isDirty,
                prNumber: info?.prNumber,
                prURL: info?.prURL
            )
        } else {
            model.setRepoStatus(isDirty: nil, prNumber: nil, prURL: nil)
        }
    }

    /// The project a worktree tab belongs to, or nil for a tab that is not in
    /// one.
    ///
    /// Guarded by the string check first, so the two small file reads
    /// `GitCommonDir` does only happen for tabs actually inside the managed
    /// root — which keeps the 5-second timer's cost where it was for
    /// everybody else.
    private static func worktreeRepo(forRepoRoot root: String?, pwd: String?) -> String? {
        guard GitWorktreeMembership.contains(pwd: pwd, root: WorktreeSettings.managedRoot),
              let root, !root.isEmpty,
              let mainCheckout = GitCommonDir.resolve(from: root)
        else { return nil }
        return WorktreePath.repoName(mainCheckout: mainCheckout)
    }

    /// Surface publishers update the model directly — no list refresh.
    private func subscribe(_ model: SidebarTabModel, to surface: Ghostty.SurfaceView?) {
        guard let surface, model.surfaceCancellables.isEmpty else { return }

        surface.$title
            .removeDuplicates()
            .sink { [weak model] _ in
                guard let model else { return }
                model.setTitle(model.window.title)
            }
            .store(in: &model.surfaceCancellables)

        surface.$pwd
            .removeDuplicates()
            .sink { [weak self, weak model] pwd in
                guard let self, let model else { return }
                self.applyPwd(pwd, to: model)
            }
            .store(in: &model.surfaceCancellables)
    }

    private func bumpGrouping() {
        groupingVersion &+= 1
    }

    /// New tabs are placed at the top or bottom of the sidebar order,
    /// per the user's setting.
    private func registerNewTab(
        _ model: SidebarTabModel,
        controller: BaseTerminalController
    ) {
        let surface = controller.focusedSurface
            ?? controller.surfaceTree.root?.leftmostLeaf()
        guard let surfaceId = surface?.id else { return }

        let atStart = UserDefaults.standard.string(
            forKey: "SidebarNewTabPosition"
        ) == "start"
        SidebarGroupStore.shared.registerNewTab(surfaceId: surfaceId, atStart: atStart)
    }

    /// The periodic pass: re-reads what changes with no notification to
    /// hang off of — git state, and the process each tab is running.
    private func refreshMetadata() {
        guard isSidebarVisible else { return }

        for model in models {
            let git = Self.gitInfo(for: model.pwd)
            model.setGit(branch: git?.branch, root: git?.root)
            model.setInManagedWorktree(
                GitWorktreeMembership.contains(pwd: model.pwd, root: WorktreeSettings.managedRoot),
                repo: Self.worktreeRepo(forRepoRoot: git?.root, pwd: model.pwd))
            if let git {
                GitStatusCenter.shared.requestRefresh(root: git.root, branch: git.branch)
            }
        }

        for tabWindow in groupWindows {
            guard let controller = tabWindow.windowController as? BaseTerminalController,
                  let model = modelsById[ObjectIdentifier(tabWindow)]
            else { continue }
            applyDevServer(
                controller.focusedSurface ?? controller.surfaceTree.root?.leftmostLeaf(),
                to: model
            )
        }
    }

    /// Activates the given tab (window) within the group.
    ///
    /// Only if that window is still open. `makeKeyAndOrderFront` does not
    /// refuse a closed window — it *re-shows* it, and what comes back is a
    /// husk: `windowWillClose` has already cleared the content view and
    /// dropped the sidebar chrome, so the reader clicking a tab gets a bare
    /// window arriving from nowhere instead of the tab they asked for. A row
    /// that has outlived its window is stale rather than actionable, so the
    /// list is re-formed instead and the row goes away.
    func select(_ model: SidebarTabModel) {
        guard Self.isLiveTab(model.window) else {
            WindowBreadcrumbs.note(
                "sidebar select: window=\(model.window.windowNumber) not live -> refresh")
            refresh()
            return
        }
        WindowBreadcrumbs.note(
            "sidebar select: window=\(model.window.windowNumber) group=\(model.window.tabGroup?.windows.count ?? 0)")
        model.window.makeKeyAndOrderFront(nil)
    }

    /// Resolves the repository root and current branch for a working
    /// directory by walking up to `.git` and reading `HEAD` directly —
    /// no git execution. Worktrees (a `.git` file pointing at the real
    /// git dir) are followed; a detached HEAD yields the short hash.
    nonisolated static func gitInfo(for pwd: String?) -> (root: String, branch: String?)? {
        guard let pwd, !pwd.isEmpty else { return nil }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: pwd)

        for _ in 0..<16 {
            let gitURL = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: gitURL.path, isDirectory: &isDir) {
                let headURL: URL
                if isDir.boolValue {
                    headURL = gitURL.appendingPathComponent("HEAD")
                } else {
                    guard let content = try? String(contentsOf: gitURL, encoding: .utf8),
                          content.hasPrefix("gitdir:")
                    else { return (dir.path, nil) }
                    let path = content.dropFirst("gitdir:".count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let gitDir = path.hasPrefix("/")
                        ? URL(fileURLWithPath: path)
                        : dir.appendingPathComponent(path)
                    headURL = gitDir.appendingPathComponent("HEAD")
                }

                guard let head = try? String(contentsOf: headURL, encoding: .utf8)
                else { return (dir.path, nil) }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: refs/heads/") {
                    return (dir.path, String(trimmed.dropFirst("ref: refs/heads/".count)))
                }
                return (dir.path, String(trimmed.prefix(7)))
            }

            if dir.path == "/" { break }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}