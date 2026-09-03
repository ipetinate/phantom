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

    /// Whether the WindowServer actually has this window on screen.
    ///
    /// The one answer in this family that cannot be half-committed: AppKit's
    /// `isVisible` and `occlusionState` both told different lies at
    /// different moments, while `kCGWindowIsOnscreen` matched the pixels
    /// every time it was measured.
    static func windowServerShowsOnScreen(_ window: NSWindow) -> Bool {
        guard window.windowNumber > 0 else { return false }
        let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
        guard let info = list?.first else { return false }
        return info[kCGWindowIsOnscreen as String] as? Bool ?? false
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
            forName: .ghosttyCommandDidStart, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.applyCommandSignal(.shellStarted, from: notification)
            }
        })

        notificationObservers.append(center.addObserver(
            forName: .ghosttyCommandDidFinish, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.applyCommandSignal(
                    Self.finishSignal(from: notification),
                    from: notification
                )
            }
        })

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
                    self.applyCommandRun(model, signal: .tick)
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
                    self.applyCommandRun(model, signal: .tick)
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
                        conflicts: info.conflicts,
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
                        self.applyCommandRun(model, signal: .tick)
                        continue
                    }
                    model.setDevServerPort(servers[pid]?.port)
                    self.applyCommandRun(model, signal: .tick)
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
                if !PhantomSessionStore.shared.isRestoring {
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
            applyCommandRun(model, signal: .tick)
            return
        }

        model.setForegroundPID(pid)
        model.setDevServerPort(DevServerCenter.shared.port(forPID: pid))
        DevServerCenter.shared.requestRefresh(pid: pid)
        applyCommandRun(model, signal: .tick)
    }

    /// Folds a tab's own facts through `CommandRunRule`, which is where the
    /// marks for a plain command come from.
    ///
    /// Every signal goes through here, the shell's reports included, so that
    /// one function owns the state and the rule sees the same facts whichever
    /// signal woke it. Called from every path that can change one of those
    /// facts, not from the poll alone: the agent centers publish between
    /// polls, and a mark inferred for a command must not outlive the moment an
    /// agent takes the row over — the row would then draw a command's dot for
    /// a session that is running.
    ///
    /// The process name is the one `setForegroundPID` already resolved. The
    /// alternate screen is read live, because it is the answer to "is this a
    /// full-screen program" and a stale answer to that draws a spinner for an
    /// editor.
    private func applyCommandRun(
        _ model: SidebarTabModel,
        signal: CommandRunRule.Signal
    ) {
        model.setCommandRun(CommandRunRule.next(
            after: model.commandRun,
            signal: signal,
            facts: CommandRunRule.Facts(
                foreground: CommandRunRule.foreground(name: model.foregroundName),
                isAlternateScreen: surface(for: model)?.surfaceModel?.isAlternateScreen ?? false,
                hasAgentState: model.agentState != nil,
                hasLiveAgent: model.liveAgent != nil,
                hasDevServerPort: model.devServerPort != nil,
                isSelected: model.isSelected
            ),
            now: Date()
        ))

        if case .shellStarted = signal, case .pending = model.commandRun?.phase {
            scheduleCommandTick(model)
        }
    }

    /// Brings the wait after a reported start to an end.
    ///
    /// Without this the row would sit in `pending` until the 5-second poll
    /// noticed, which is the latency the shell's report exists to remove. The
    /// slack is there because the rule compares against a duration and a
    /// deadline that lands a hair early would leave the tab waiting a whole
    /// poll.
    ///
    /// Nothing is cancelled and nothing is stored. A tick that arrives after
    /// the command already finished finds a phase the rule leaves alone, which
    /// is cheaper than tracking one timer per tab.
    private func scheduleCommandTick(_ model: SidebarTabModel) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CommandRunRule.shellMinimumDuration + 0.1
        ) { [weak self, weak model] in
            guard let self, let model else { return }
            self.applyCommandRun(model, signal: .tick)
        }
    }

    /// The surface a row stands for, which is the one every other fact about
    /// the tab is already read from.
    private func surface(for model: SidebarTabModel) -> Ghostty.SurfaceView? {
        guard let controller = model.window?.windowController as? BaseTerminalController
        else { return nil }
        return controller.focusedSurface ?? controller.surfaceTree.root?.leftmostLeaf()
    }

    /// Routes one of the shell's own command reports to the row it happened
    /// in.
    ///
    /// Matched on the surface, not on the window: a window can hold several
    /// splits and a row stands for one of them, the same one every other fact
    /// on the row is read from. A report from any other split is dropped
    /// rather than drawn on the wrong row.
    private func applyCommandSignal(
        _ signal: CommandRunRule.Signal,
        from notification: Notification
    ) {
        guard let view = notification.object as? Ghostty.SurfaceView,
              let model = models.first(where: { $0.surfaceId == view.id })
        else { return }
        applyCommandRun(model, signal: signal)
    }

    /// The finish signal, read out of the notification the app posts ahead of
    /// the `notify-on-command-finish` settings.
    ///
    /// A missing exit code stays missing: `-1` means the shell reported none,
    /// and reading that as zero would call every such command a success.
    static func finishSignal(from notification: Notification) -> CommandRunRule.Signal {
        let info = notification.userInfo
        let nanoseconds = info?[Notification.Name.CommandDurationKey] as? UInt64 ?? 0
        return .shellFinished(
            exitCode: info?[Notification.Name.CommandExitCodeKey] as? Int,
            duration: TimeInterval(nanoseconds) / 1_000_000_000
        )
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
                conflicts: info?.conflicts,
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
                guard let model, let window = model.window else { return }
                model.setTitle(window.title)
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

    /// Puts a tab this sidebar has just met into the persisted display
    /// order, at the top or bottom per the user's setting.
    ///
    /// Every newly seen tab is registered, including the window's own tab
    /// during `init`. The `init` pass used to be skipped, and that skip was
    /// a bug with a delayed fuse: a window's first tab stayed out of
    /// `SidebarGroupStore.tabOrder`, `sorted` places unordered tabs after
    /// ordered ones, so that first tab sat pinned to the bottom of the list
    /// and every tab created afterwards sorted in *front* of it — the "new
    /// terminal lands second-to-last" report, frozen into the on-disk
    /// `tabOrder` the day this was diagnosed. The first quit-and-restore
    /// registered everything and hid the bug, which is why it only ever
    /// showed on a fresh install.
    ///
    /// The one moment a newly seen tab must not be registered is while
    /// `PhantomSessionStore` is restoring: restored tabs are already in the
    /// persisted order (registering is a no-op), and tabs from a file that
    /// predates the order must keep their native relative order, which the
    /// post-restore refresh preserves by appending them as it walks the
    /// group. The caller holds that guard.
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
    /// Whether a select may fetch its window, as a rule rather than as an
    /// expression inside a method — the shape `WindowGhostRescue.shouldRescue`
    /// established for the same reason: the interesting part is when the answer
    /// is *no*, and no is the answer nobody sees happen.
    ///
    /// - Parameters:
    ///   - appIsActive: `NSApp.isActive`. True for every select the reader
    ///     makes, because their click landed in this app.
    ///   - isOnActiveSpace: `NSWindow.isOnActiveSpace`. False when the window
    ///     is on a Space other than the one in front — where ordering it front
    ///     moves it rather than switching to it.
    static func mayOrderFront(appIsActive: Bool, isOnActiveSpace: Bool) -> Bool {
        appIsActive || isOnActiveSpace
    }

    func select(_ model: SidebarTabModel) {
        guard let w = model.window, Self.isLiveTab(w) else {
            WindowBreadcrumbs.note(
                "sidebar select: window=\(model.window?.windowNumber ?? -1) not live -> refresh")
            refresh()
            return
        }
        WindowBreadcrumbs.note(
            "sidebar select: window=\(w.windowNumber) group=\(w.tabGroup?.windows.count ?? 0) "
            + "visible=\(w.isVisible) occl=\(w.occlusionState.rawValue) "
            + "active=\(NSApp.isActive) onActiveSpace=\(w.isOnActiveSpace)")

        /// **A select that nobody in this app asked for does not fetch the
        /// window.**
        ///
        /// `makeKeyAndOrderFront` on a window that is not on the active Space
        /// does not switch Spaces — it *moves the window* to the Space in
        /// front. For the reader's own click that is invisible, because their
        /// click happened in this app, on the Space they are looking at. For a
        /// select that arrives from somewhere else it is the bug reported
        /// against 0.13: an agent's command opened a browser, the reader's
        /// Space switched to it, something selected a tab — and the terminal
        /// window followed them onto the browser's Space, out of the Space they
        /// keep it on.
        ///
        /// So when this app is not the active one and the window is elsewhere,
        /// the tab is selected *inside its group* and nothing is ordered
        /// anywhere. The reader finds it selected when they come back, which is
        /// what a select is for; being yanked across Spaces is not.
        guard Self.mayOrderFront(appIsActive: NSApp.isActive, isOnActiveSpace: w.isOnActiveSpace)
        else {
            WindowBreadcrumbs.note(
                "sidebar select: deferred — app inactive and window=\(w.windowNumber) "
                + "is on another Space; selecting in its group instead")
            w.tabGroup?.selectedWindow = w
            refresh()
            return
        }

        w.makeKeyAndOrderFront(nil)

        /// Verified rather than trusted, a turn later. This family of bugs
        /// keeps producing windows that answer every AppKit question
        /// correctly and still put no pixel on screen — `isVisible` true
        /// with the WindowServer reporting offscreen, then the inverse, a
        /// window `isVisible` false whose occlusion claims visibility. Each
        /// spelling was one launch-ordering race away from the last. The
        /// select is the one gesture whose outcome the reader is looking
        /// straight at, so it checks its own work: if the window it just
        /// ordered front is not actually the visible front a turn later, it
        /// is ordered out and front again — a fresh WindowServer commit from
        /// a clean dispatch — and the breadcrumb says so, so the next
        /// variant of this arrives already witnessed.
        /// Verified against the WindowServer, not against AppKit. This
        /// family produced both polarities of the same lie — `isVisible`
        /// true with the WindowServer reporting offscreen, and the inverse —
        /// so any check written over NSWindow state alone either misses one
        /// variant or fires on healthy clicks. `CGWindowListCopyWindowInfo`
        /// is the ground truth both were measured with, it answers for one
        /// window cheaply, and it is synchronous. The delay gives a healthy
        /// commit time to land; occlusion is never consulted (it updates
        /// asynchronously and rescued every ordinary click), and the re-show
        /// never orders out (ordering a tabbed window out detaches it from
        /// its group — the first spelling of this rescue manufactured loose
        /// windows one click at a time).
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak w] in
            /// Still the reader's latest choice — another click since moves
            /// key elsewhere, and rescuing the previous window would steal
            /// the focus right back.
            guard let w, w.isKeyWindow else { return }

            /// A window on another Space is reported offscreen by the
            /// WindowServer, and it is not a ghost — it is a window where the
            /// reader put it. Rescuing it would drag it to whichever Space is
            /// in front, which is the fault this rescue would otherwise become.
            guard w.isOnActiveSpace else {
                WindowBreadcrumbs.note(
                    "select rescue: window=\(w.windowNumber) is on another Space — not a ghost")
                return
            }
            guard !Self.windowServerShowsOnScreen(w) else { return }
            WindowBreadcrumbs.note(
                "select rescue: window=\(w.windowNumber) key but offscreen "
                + "per WindowServer (visible=\(w.isVisible)) — re-showing")
            w.orderFrontRegardless()
            w.makeKey()
        }
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