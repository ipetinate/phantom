import AppKit
import Combine

/// One tab's live state, observed individually by its sidebar row.
///
/// Fine-grained models are the core of the sidebar's update strategy:
/// the list only publishes on membership/order changes, while title,
/// pwd, git and agent-state changes touch a single model — so a single
/// row re-renders instead of the whole list.
@MainActor
final class SidebarTabModel: ObservableObject, Identifiable {
    nonisolated let id: ObjectIdentifier

    /// The tab's window — weak, because the window dies before the model
    /// does, by design: closing a tab deallocates its window while the row
    /// standing for it is still in the SwiftUI tree, and stays there until
    /// the next `SidebarTabManager.refresh` drops the model. This was
    /// `unowned`, and that was a crash with the app's name on it: the row's
    /// one render between the close and the refresh read `window`, the
    /// Swift runtime hit a freed unowned reference, and the whole process
    /// aborted — "closing a tab quit the app", reproduced under lldb with
    /// `swift_abortRetainUnowned` in `SidebarTabRow.tabEditorCenter`.
    ///
    /// Not strong, deliberately: `NSWindow.windowController` retains the
    /// controller, the controller owns the `SidebarTabManager`, and the
    /// manager holds these models — a strong reference here closes that
    /// loop and no terminal window could ever deallocate again, which is
    /// the shell-leak family `releaseSidebarChrome` exists to prevent.
    ///
    /// A nil window means the row is a corpse the next refresh will
    /// remove; readers render it inert rather than acting on it.
    weak private(set) var window: NSWindow?

    @Published private(set) var title: String = ""
    @Published private(set) var pwd: String?
    @Published private(set) var surfaceId: UUID?
    @Published private(set) var isSelected = false
    @Published private(set) var needsAttention = false
    @Published private(set) var gitBranch: String?
    @Published private(set) var repoRoot: String?

    /// Whether the tab's cwd sits inside the managed worktree root — the fact
    /// the branch chip's glyph changes on. An O(1) string check,
    /// deliberately: it is refreshed on the same paths as the branch, one of
    /// which is a 5-second timer that promises to run no git.
    @Published private(set) var isInManagedWorktree = false

    /// The repository a worktree tab belongs to, for the chip that would
    /// otherwise repeat the branch.
    ///
    /// The folder of a worktree is `<repo>-<branch>`, so its last component
    /// says the branch twice and the project once, jumbled. This is the
    /// project on its own, read from the main checkout.
    ///
    /// Resolved **only** for tabs inside the managed root, and the cost is
    /// worth saying out loud: it is two reads of a small file on the same
    /// path as the 5-second metadata timer. That path promises no *git
    /// subprocess*, and it still keeps that promise — but it is no longer
    /// free, and it is bounded to worktree tabs on purpose.
    @Published private(set) var worktreeRepo: String?
    @Published private(set) var agentState: AgentTabState?

    /// The agent whose session is up in this tab, which `agentState` cannot
    /// say: that is nil both for a tab with no agent and for one whose agent is
    /// idle. Rows that show something *about* a session — the plan tag — need
    /// the difference.
    @Published private(set) var liveAgent: CodingAgent?

    @Published private(set) var isDirty: Bool?

    /// How many paths in this terminal's repository git could not merge, or
    /// nil when it is not in one — or when nothing is known about it yet.
    @Published private(set) var conflicts: Int?
    @Published private(set) var prNumber: Int?
    @Published private(set) var prURL: String?

    /// The PTY's foreground process group, used to find a dev server
    /// running anywhere below it.
    @Published private(set) var foregroundPID: Int?

    /// The executable name of that process — `vim`, `node`, or the shell
    /// itself when the terminal is sitting at a prompt.
    @Published private(set) var foregroundName: String?

    /// The port a dev server in this tab is listening on, if any.
    @Published private(set) var devServerPort: Int?

    /// How far along a plain command in this tab is — one no agent hook
    /// reports, so it is inferred rather than told. See `CommandRunRule`,
    /// which owns every transition of it.
    @Published private(set) var commandPhase: CommandRunPhase?

    /// The mark the row draws for that command, which the phase before the
    /// minimum duration deliberately has none of.
    var commandMark: CommandRunMark? { commandPhase?.mark }

    var surfaceCancellables: Set<AnyCancellable> = []

    var directoryName: String? {
        guard let pwd, !pwd.isEmpty else { return nil }
        return (pwd as NSString).lastPathComponent
    }

    init(window: NSWindow) {
        self.id = ObjectIdentifier(window)
        self.window = window
    }

    /// Each setter publishes only on a real change, keeping row
    /// re-renders scoped to actual updates.

    func setTitle(_ value: String) {
        if title != value { title = value }
    }

    func setPwd(_ value: String?) {
        if pwd != value { pwd = value }
    }

    func setSurfaceId(_ value: UUID?) {
        if surfaceId != value { surfaceId = value }
    }

    func setSelected(_ value: Bool) {
        if isSelected != value { isSelected = value }
    }

    func setNeedsAttention(_ value: Bool) {
        if needsAttention != value { needsAttention = value }
    }

    func setGit(branch: String?, root: String?) {
        if gitBranch != branch { gitBranch = branch }
        if repoRoot != root { repoRoot = root }
    }

    func setInManagedWorktree(_ value: Bool, repo: String?) {
        if isInManagedWorktree != value { isInManagedWorktree = value }
        if worktreeRepo != repo { worktreeRepo = repo }
    }

    func setAgentState(_ value: AgentTabState?) {
        if agentState != value { agentState = value }
    }

    func setLiveAgent(_ value: CodingAgent?) {
        if liveAgent != value { liveAgent = value }
    }

    func setRepoStatus(isDirty: Bool?, conflicts: Int? = nil, prNumber: Int?, prURL: String?) {
        if self.isDirty != isDirty { self.isDirty = isDirty }
        if self.conflicts != conflicts { self.conflicts = conflicts }
        if self.prNumber != prNumber { self.prNumber = prNumber }
        if self.prURL != prURL { self.prURL = prURL }
    }

    /// Resolves the process name alongside the pid, so the sidebar can say
    /// *what* a terminal is running rather than only that something is.
    ///
    /// Only looked up when the pid actually changes: the name comes from a
    /// syscall, and this is called on every metadata refresh.
    func setForegroundPID(_ value: Int?) {
        guard foregroundPID != value else { return }
        foregroundPID = value
        foregroundName = value.flatMap(TerminalIdleCheck.processName)
    }

    func setDevServerPort(_ value: Int?) {
        if devServerPort != value { devServerPort = value }
    }

    func setCommandPhase(_ value: CommandRunPhase?) {
        if commandPhase != value { commandPhase = value }
    }
}
