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
}
