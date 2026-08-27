import Foundation

/// Which of the packages in `LSPDependencyCatalog` are on this machine, and at
/// what version.
///
/// Separate from `LSPCenter.installedCommands` because it answers a different
/// question by a different means. That one asks "is a binary on the login
/// `PATH`", which is a handful of `stat`s and is the only thing a launch
/// cares about. This one asks "is a package under `npm root -g`, and is it the
/// version we pinned" — which needs a subprocess, and which is the only way to
/// see `@vue/typescript-plugin` at all, since it ships no binary.
///
/// **One subprocess for the whole screen, never in a `body`.** `npm root -g`
/// is resolved once off the main actor and published; the popover reads the
/// published dictionary. The failure this shape exists to avoid is the one
/// `installedCommands` already fixed once: a view that asked the shell a
/// question per row and blocked the main actor twenty times to draw a window.
@MainActor
final class LSPDependencyCenter: ObservableObject {
    static let shared = LSPDependencyCenter()

    /// Package name to the version found under the global `node_modules`. A
    /// package absent from this dictionary is absent from the machine — or
    /// installed somewhere npm does not own, which `LSPDependencyCatalog`
    /// treats as present-but-unversioned rather than missing.
    @Published private(set) var globalVersions: [String: String] = [:]

    /// Whether the probe has answered at least once. Until it has, every
    /// status is `.unknown` and the popover says so rather than guessing.
    @Published private(set) var hasProbed = false

    private var isProbing = false
    private var probeRequestedAgain = false

    /// Re-reads the global packages, off the main actor.
    ///
    /// Coalesced the same way `LSPCenter.refreshInstalledCommands` is, and for
    /// the same reason: a request arriving *during* a probe is asked again
    /// afterwards rather than dropped, because the probe in flight read the
    /// filesystem before whatever just changed it — which is exactly the
    /// install whose new package would otherwise stay invisible.
    func refresh() {
        guard !isProbing else {
            probeRequestedAgain = true
            return
        }
        isProbing = true

        let packages = LSPDependencyCatalog.allPackages
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                LSPDependencyCatalog.globalVersions(of: packages)
            }.value

            guard let self else { return }
            self.isProbing = false

            /// A probe that could not run leaves everything as it was. Writing
            /// `[:]` here is what made a failed read look like a machine with
            /// nothing installed — see `LSPDependencyCatalog.globalVersions`.
            /// `hasProbed` stays false until one actually answers, so the pane
            /// says `.unknown` instead of `.missing`.
            if let found {
                self.hasProbed = true
                self.globalVersions = found
            }

            guard self.probeRequestedAgain else { return }
            self.probeRequestedAgain = false
            self.refresh()
        }
    }

    /// The status of every dependency in a plan, or all `.unknown` while
    /// either probe is still out.
    ///
    /// Both probes are required, not just this one: a plan mixes packages seen
    /// on `PATH` with packages seen under `npm root -g`, and answering with
    /// half the evidence would report a binary as missing for as long as the
    /// `PATH` probe takes.
    func statuses(
        for plan: LSPServerDependencyPlan,
        installedCommands: Set<String>,
        commandsProbed: Bool
    ) -> [String: LSPDependencyStatus] {
        guard hasProbed, commandsProbed else {
            return Dictionary(uniqueKeysWithValues: plan.packages.map { ($0.id, .unknown) })
        }
        return LSPDependencyCatalog.statuses(
            for: plan,
            installedCommands: installedCommands,
            globalVersions: globalVersions
        )
    }
}
