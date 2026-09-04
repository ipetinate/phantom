import Combine
import Foundation

/// Which agent CLIs are on this machine, and which package managers could
/// install the rest.
///
/// Nothing in this app asked that question before. The sidebar types
/// `agent.launchCommand` into a live shell and lets the shell answer — which is
/// the right answer for a terminal and no answer at all for a panel that wants
/// to offer an install.
///
/// Modelled on `LSPCenter`'s probe, down to the two failure modes it documents,
/// because they are the two that make an install button worse than none:
///
/// - **Answering before the probe has run.** `hasProbed` is published
///   separately so a card can say "Checking…" rather than "Install", which is
///   how somebody reinstalls what they already have.
/// - **A `PATH` read before the install that just finished.** A request that
///   arrives mid-probe is asked again rather than dropped, `LoginEnvironment`
///   is invalidated before the post-install probe, and a watcher over the login
///   `PATH` directories catches the write itself — `npm i -g` and `brew
///   install` both end by creating an entry in a bin directory.
///
/// The resolved **path** is kept, not a boolean. `pi` and `agy` are short
/// names, and `PATH` cannot tell an agent from something else that happens to
/// be called that; showing where it was found is the only way anybody spots the
/// wrong one.
@MainActor
final class AgentAvailability: ObservableObject {
    static let shared = AgentAvailability()

    /// Where each agent's command was found. A missing entry after
    /// ``hasProbed`` means it is not installed.
    @Published private(set) var resolved: [CodingAgent: String] = [:]

    /// The same, for the package managers the install table names.
    @Published private(set) var managers: [AgentPackageManager: String] = [:]

    /// Whether the first probe has answered. Until it has, nothing here is a
    /// statement about the machine.
    @Published private(set) var hasProbed = false

    private var isProbing = false
    private var probeRequestedAgain = false
    private var pathWatcher: DirectoryWatcher?

    private init() {}

    func path(for agent: CodingAgent) -> String? { resolved[agent] }

    func isInstalled(_ agent: CodingAgent) -> Bool { resolved[agent] != nil }

    /// The managers this machine has, for `AgentInstallPlan.command(for:managers:)`.
    var availableManagers: Set<AgentPackageManager> { Set(managers.keys) }

    /// Looks for every agent and every manager, off the main actor.
    ///
    /// One pass for both, so a card can say "Homebrew not found" instead of
    /// streaming an error from a command whose first word is missing.
    func refresh() {
        guard !isProbing else {
            probeRequestedAgain = true
            return
        }
        isProbing = true

        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                () -> ([CodingAgent: String], [AgentPackageManager: String]) in
                let searchPath = LoginEnvironment.executableSearchPath()

                var agents: [CodingAgent: String] = [:]
                for agent in CodingAgent.allCases {
                    guard let path = LSPProcess.locate(agent.launchCommand, searchPath: searchPath)
                    else { continue }
                    agents[agent] = path
                }

                var managers: [AgentPackageManager: String] = [:]
                for manager in AgentPackageManager.allCases {
                    guard let path = LSPProcess.locate(manager.command, searchPath: searchPath)
                    else { continue }
                    managers[manager] = path
                }

                return (agents, managers)
            }.value

            guard let self else { return }
            self.isProbing = false
            self.hasProbed = true
            self.resolved = found.0
            self.managers = found.1

            guard self.probeRequestedAgain else { return }
            self.probeRequestedAgain = false
            self.refresh()
        }
    }

    /// What a finished install calls.
    ///
    /// The invalidation is the point: a version manager puts its shims on a
    /// `PATH` this app cached at first use, and the newly installed binary is
    /// invisible until that cache is dropped. `LSPCenter.recheckMissingServers`
    /// learned the same lesson.
    func noteAvailabilityChanged() {
        LoginEnvironment.invalidate()
        refresh()
    }

    /// Watches the login `PATH` so an install done in a terminal — or by the
    /// card next door — is noticed without anybody pressing anything.
    ///
    /// Started by the first view that needs it rather than at launch: this is a
    /// settings-and-welcome question, and a watcher over fifteen directories is
    /// not something to hold for a reader who never opens either.
    func startWatchingPath() {
        guard pathWatcher == nil else { return }

        Task { [weak self] in
            let directories = await Task.detached(priority: .utility) {
                Set((LoginEnvironment.loginPath() ?? "").split(separator: ":").map(String.init))
            }.value

            guard let self, !directories.isEmpty else { return }
            let watcher = DirectoryWatcher()
            watcher.onChange = { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            watcher.watch(directories)
            self.pathWatcher = watcher
        }
    }
}
