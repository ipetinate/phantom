import SwiftUI

/// One panel the sidebar can show.
///
/// The sidebar started out only able to list terminals. This enum is the
/// seam that lets it hold more: adding a panel is a case here plus a branch
/// in `SidebarView.paneContent` and, if it needs its own titlebar buttons,
/// one in `SidebarTitlebarChrome`. Nothing in the AppKit hierarchy
/// (`TerminalController.makeSidebarSplitView`) has to change.
///
enum SidebarPane: String, CaseIterable, Identifiable, Codable {
    case terminals
    case files
    case git
    case worktrees

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminals: return "Terminals"
        case .files: return "Files"
        case .git: return "Git"
        case .worktrees: return "Worktrees"
        }
    }

    /// SF Symbol for the tab bar, or nil for a panel that ships its own
    /// artwork (see `SidebarPaneIcon`) — git and worktrees both do.
    var symbol: String? {
        switch self {
        case .terminals: return "terminal"
        case .files: return "folder"
        case .git: return nil
        case .worktrees: return nil
        }
    }

    /// Terminals is the sidebar's reason to exist, so it can't be turned
    /// off; the rest are opt-out.
    var canBeHidden: Bool { self != .terminals }

    var defaultsKey: String? {
        switch self {
        case .terminals: return nil
        case .files: return "SidebarShowFilesPane"
        case .git: return "SidebarShowGitPane"
        case .worktrees: return "SidebarShowWorktreesPane"
        }
    }

    var isEnabled: Bool {
        guard let defaultsKey else { return true }
        return UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The panels to actually offer, in tab order.
    static var enabled: [SidebarPane] {
        allCases.filter(\.isEnabled)
    }

    /// With only terminals left there is nothing to switch between, so the
    /// tab bar hides itself entirely and the sidebar goes back to being the
    /// plain terminal list it started as.
    static var showsTabBar: Bool {
        enabled.count > 1
    }
}

/// A panel's icon, whether it comes from SF Symbols or the asset catalog.
struct SidebarPaneIcon: View {
    let pane: SidebarPane
    var size: CGFloat = 10

    var body: some View {
        if let symbol = pane.symbol {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
        } else if pane == .worktrees {
            WorktreeIcon(size: size + 2)
        } else {
            GitIcon(size: size + 1)
        }
    }
}
