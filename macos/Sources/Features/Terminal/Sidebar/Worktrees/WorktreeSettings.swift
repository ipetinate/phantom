import Foundation

/// Where worktrees this app creates are kept.
///
/// The one owner of the preference, so that the pane, the create flow and
/// the orphan check all read the same folder. Two readers with their own
/// idea of the default would disagree about which worktrees are managed,
/// and the orphan list would either miss them or claim the user's own.
enum WorktreeSettings {
    static let defaultsKey = "WorktreeManagedRoot"

    /// The configured root, tilde-expanded and ready to compare against a
    /// path from git.
    static var managedRoot: String {
        expand(UserDefaults.standard.string(forKey: defaultsKey))
    }

    /// The preference's stored form turned into an absolute path.
    ///
    /// Unset and empty are the same case on purpose: a text field the user
    /// cleared writes `""`, not `nil`, and both mean "I never chose", which
    /// is the default rather than the filesystem root.
    ///
    /// A tilde is expanded because the preference is something a person
    /// types, and `~/code/worktrees` compared against git's absolute paths
    /// matches nothing at all — the same expansion
    /// `SidebarGroup.claims(pwd:)` does to a group root, for the same
    /// reason.
    nonisolated static func expand(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = trimmed.isEmpty ? defaultRoot : trimmed
        return (value as NSString).expandingTildeInPath
    }

    /// Under the app's own dot-directory rather than somewhere in
    /// `~/Documents`: these folders are working state, they can be large,
    /// and they should not turn up in a backup or a Spotlight result as if
    /// they were the user's own copies of a project.
    private static let defaultRoot = "~/.phantom/worktrees"
}
