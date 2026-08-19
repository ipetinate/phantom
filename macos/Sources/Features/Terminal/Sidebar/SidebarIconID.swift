import Foundation

/// How a chosen icon is written down.
///
/// A group's or a tab's icon has always been one string holding one of two
/// things: an SF Symbol name, or a single emoji. The agents' marks are neither
/// — they are views this app draws — so they need a third form, and it has to
/// be a form the first two cannot accidentally take.
///
/// `agent:` does that. No SF Symbol name contains a colon, and no emoji is
/// seven ASCII characters, so an old icon can never be read as an agent and an
/// agent never as a symbol. It also survives being stored: the icon is written
/// to disk as-is, so a build that does not know a name still round-trips it
/// instead of dropping it.
enum SidebarIconID {
    private static let agentPrefix = "agent:"

    /// The stored form of an agent's mark.
    static func id(for agent: CodingAgent) -> String {
        agentPrefix + agent.rawValue
    }

    /// The agent an icon names, or nil when it names anything else.
    ///
    /// Nil for `agent:` followed by a name this build does not know, which is
    /// what a file written by a newer version looks like. The caller then
    /// falls back to the default symbol — an unfamiliar agent shows the plain
    /// icon rather than an empty box where an icon should be.
    static func agent(for icon: String) -> CodingAgent? {
        guard icon.hasPrefix(agentPrefix) else { return nil }
        return CodingAgent(rawValue: String(icon.dropFirst(agentPrefix.count)))
    }
}
