import Foundation

/// Which agent buttons a profile that has never opened Settings sees.
///
/// Claude Code alone. The others are installed by far fewer readers than a
/// mark each on every surface implied, and the row paid for them in width on
/// the toolbar, on every group header and on every terminal row. Turning one
/// on is a single switch in Settings, Sidebar pane; turning the rest off was
/// a switch each across three sections.
///
/// This is why a new agent arrives switched off, and it is a statement about
/// the default rather than about the agent: nothing here is a judgement on
/// which agent is worth using.
///
/// The keys behind those buttons — one per surface per agent — are declared
/// with `@AppStorage` in four views, and `@AppStorage` keeps its fallback
/// inside the property wrapper. Spelled out four times, the fallback drifts:
/// the first view SwiftUI builds decides what the other three meant, so the
/// answer would depend on the layout. The fact is therefore named once here
/// and every declaration reads it.
enum AgentButtonDefaults {
    /// The agents whose buttons are on out of the box.
    static let shown: Set<CodingAgent> = [.claude]

    /// The per-key form the `@AppStorage` declarations need.
    static func isShown(_ agent: CodingAgent) -> Bool { shown.contains(agent) }

    /// The key behind one agent's button in one place.
    ///
    /// The eighteen keys were spelled out as literals in four views. That is
    /// one literal per surface per agent to get right, in files that have no
    /// reason to be edited together — and a key typed slightly differently is
    /// not an error anybody sees. It reads as a switch that will not stay on,
    /// because `@AppStorage` writes the typo and the view that spelled it
    /// correctly goes on reading the old one.
    ///
    /// Now the fallback and the key are named in the same place, which is what
    /// makes them impossible to disagree.
    static func key(_ surface: AgentButtonSurface, _ agent: CodingAgent) -> String {
        surface.prefix + token(agent)
    }

    /// The agent's spelling inside a key, which is **not** its display name and
    /// not its raw value — see `AgentDescriptor.settingsKeyToken`.
    private static func token(_ agent: CodingAgent) -> String {
        agent.descriptor.settingsKeyToken
    }

    static func isShown(
        _ surface: AgentButtonSurface,
        _ agent: CodingAgent,
        stored: (String) -> Bool?
    ) -> Bool {
        stored(key(surface, agent)) ?? isShown(agent)
    }
}

/// Where an agent's button can appear.
///
/// The same three places `WorktreeEntry` names for the worktree button, and
/// deliberately not the same type. Each feature owns the spelling of its own
/// keys, and the two conventions do not agree: the worktree button's chrome key
/// is `SidebarChromeShowWorktree` while an agent's is `SidebarShowClaude`, with
/// no `Chrome` in it. One enum would have to carry both conventions and answer
/// a different question depending on which feature asked, which is two enums
/// wearing one name.
enum AgentButtonSurface: String, CaseIterable, Sendable {
    /// The sidebar's own chrome, above everything — also drawn in the titlebar.
    case chrome

    /// The header of a group of terminals.
    case groupHeader

    /// The row of one terminal.
    case tabRow

    /// The place, in two or three words, for a control that has room for two
    /// or three words.
    var shortName: String {
        switch self {
        case .chrome: return "Toolbar"
        case .groupHeader: return "Group"
        case .tabRow: return "Tab"
        }
    }

    /// The place inside a sentence — "show it on the tab row".
    var placeName: String {
        switch self {
        case .chrome: return "in the sidebar's toolbar"
        case .groupHeader: return "on group headers"
        case .tabRow: return "on tab rows"
        }
    }

    /// The half of the key that comes before the agent.
    ///
    /// `chrome` is the odd one and stays odd. `SidebarShowClaude` is what is on
    /// disk for every reader who has ever touched that switch, and a rename to
    /// match its neighbours would silently turn their choices back into the
    /// defaults — a migration nobody asked for, to fix an inconsistency nobody
    /// can see.
    var prefix: String {
        switch self {
        case .chrome: return "SidebarShow"
        case .groupHeader: return "SidebarGroupShow"
        case .tabRow: return "SidebarTabShow"
        }
    }
}
