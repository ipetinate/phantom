import Foundation

/// What the worktrees panel is looking at.
///
/// The panel does not deal in repository roots but in **families**: one main
/// checkout together with every linked worktree sharing its object store. A
/// tab in the main checkout and a tab in one of its worktrees are looking at
/// the same family, and `GitCommonDir` is what maps either of them to the
/// single key they agree on.
///
/// The question *is this folder a repository, or does it merely hold some?*
/// is deliberately not asked again here. `GitPanelScope` already answers it
/// for the Git panel — including the part that is easy to get wrong, where a
/// scan that hasn't come back yet must not read as an empty folder — and
/// asking it a second time in a second place is how the two panels would
/// come to describe the same terminal differently. This type takes that
/// answer and converts it into the panel's own currency.
enum WorktreeScope: Equatable {
    /// One family, filling the pane. The panel this started as, and also
    /// what a workspace collapses to once its repositories turn out to
    /// belong to a single one.
    case repository(String)

    /// Several families, one collapsible section each.
    case workspace([String])

    /// Nothing here, and nothing underneath.
    case none

    /// - Parameters:
    ///   - scope: what the Git panel's resolver made of the selected
    ///     terminal.
    ///   - commonRoot: `GitCommonDir.resolve` in the panel, injected so this
    ///     derivation can be exercised without repositories on disk.
    ///
    /// Every repository is resolved on its own, and that is the point of
    /// doing this at all: a repository found by walking under a workspace
    /// folder can itself be a linked worktree, and the walk has no way of
    /// telling. Resolving only the enclosing repository — which is all the
    /// single-repository panel ever needed — would key a section on a linked
    /// worktree's own path and ask git for that path's worktree list, which
    /// answers with the whole family under a name that is one member of it.
    ///
    /// Resolved roots are then deduplicated, order preserved. A folder full
    /// of worktrees of one repository is a completely ordinary thing to keep
    /// — it is what `WorktreeSettings.managedRoot` is for — and every entry
    /// in it resolves to the same family. Without the dedup that folder
    /// becomes five identical sections, each listing the same five
    /// worktrees.
    static func resolve(
        _ scope: GitPanelScope,
        commonRoot: (String) -> String?
    ) -> WorktreeScope {
        var roots: [String] = []
        for repo in scope.repos {
            guard let root = commonRoot(repo), !root.isEmpty else { continue }
            guard !roots.contains(root) else { continue }
            roots.append(root)
        }

        switch roots.count {
        case 0:
            return .none
        case 1:
            /// One family is one family however it was arrived at. A
            /// workspace that resolved to a single repository must render as
            /// the flat panel, not as a lone section header with a
            /// disclosure triangle nobody needs to click.
            return .repository(roots[0])
        default:
            return .workspace(roots)
        }
    }

    /// Every family in this scope, in the order its sections are drawn.
    var roots: [String] {
        switch self {
        case .repository(let root): return [root]
        case .workspace(let roots): return roots
        case .none: return []
        }
    }

    /// The families a poll tick is allowed to spend git processes on.
    ///
    /// The budget, and the reason this is a function of what is open rather
    /// than just `roots`: the panel polls every 2s, and one family costs a
    /// `git worktree list` (5s TTL), a merged-branch check (60s TTL) and a
    /// `git status` **for each worktree in it** (3s TTL). That last term is
    /// the one that multiplies — twenty repositories of five worktrees each,
    /// polled indiscriminately, is a hundred `git status` every couple of
    /// seconds to keep twenty collapsed headers up to date.
    ///
    /// So a collapsed section costs nothing at all: its worktrees are never
    /// listed, and nothing is ever asked about them. Expanding one is what
    /// buys its list, and collapsing it again stops the bill. The flat case
    /// is always polled — it *is* what the reader is looking at.
    func polled(expanded: Set<String>) -> [String] {
        switch self {
        case .repository(let root): return [root]
        case .workspace(let roots): return roots.filter(expanded.contains)
        case .none: return []
        }
    }
}
