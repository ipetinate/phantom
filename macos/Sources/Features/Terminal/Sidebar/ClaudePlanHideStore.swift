import Foundation

/// The plans a reader has told the sidebar to stop showing.
///
/// Per plan rather than per row. A plan is attributed to a *project* — see
/// `ClaudePlanIndex` — so its tag appears on every terminal in that project,
/// and a hide that only cleared one row would leave the reader chasing the
/// same leftover across three tabs.
///
/// Keyed by the plan's path, which is what `ClaudePlanIndex.Plan` already
/// treats as its identity. A record whose file is gone can never matter
/// again, and this list is the one part of the feature that could grow
/// forever, so `pruned` trims it against the directory on every scan.
///
/// One key, named here, the `SidebarIconRecents` idiom: a defaults key
/// spelled inside a view gets spelled a second time by the next view that
/// needs it, and then the two spellings drift.
struct ClaudePlanHideStore {
    static let defaultsKey = "SidebarHiddenClaudePlans"

    /// `list` with `path` in it, once. Hiding what is already hidden is not
    /// a second record.
    static func hiding(_ path: String, in list: [String]) -> [String] {
        guard !path.isEmpty, !list.contains(path) else { return list }
        return list + [path]
    }

    /// `list` without `path` — what deleting a plan leaves behind.
    ///
    /// A file that is gone cannot be hidden, and Claude Code names plans
    /// from a random slug pool: keeping the record would one day meet a new
    /// plan at the same path and make it invisible on arrival.
    static func forgetting(_ path: String, in list: [String]) -> [String] {
        list.filter { $0 != path }
    }

    /// `list` without the records whose plan is no longer on disk.
    ///
    /// `existing` is the paths a directory read just returned, so the answer
    /// is about the plans that are actually there rather than about what this
    /// store last believed.
    ///
    /// An empty read prunes nothing. `ClaudePlanIndex.plans()` cannot tell an
    /// empty directory from one it failed to read, and neither is evidence
    /// that a plan is gone — so pruning on it would clear every record the
    /// reader has and bring every tag back. Nothing is lost by waiting: with
    /// no plans on disk there is no tag to hide, and the first read that
    /// finds one prunes the rest.
    static func pruned(_ list: [String], existing: Set<String>) -> [String] {
        guard !existing.isEmpty else { return list }
        return list.filter { existing.contains($0) }
    }

    private let defaults: UserDefaults

    /// `defaults` is injected so tests can run against a suite of their own,
    /// the `SidebarIconRecents` idiom. App code takes the default.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Read straight from the defaults rather than cached: the plans center
    /// is one object per app, but the store is cheap and a stale copy of
    /// this list is a tag that comes back.
    var hidden: [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func hide(_ path: String) {
        write(Self.hiding(path, in: hidden))
    }

    func forget(_ path: String) {
        write(Self.forgetting(path, in: hidden))
    }

    func prune(existing: Set<String>) {
        write(Self.pruned(hidden, existing: existing))
    }

    private func write(_ updated: [String]) {
        guard updated != hidden else { return }
        defaults.set(updated, forKey: Self.defaultsKey)
    }
}
