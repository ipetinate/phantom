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

    /// Which of the forms above an icon string is written in.
    ///
    /// Every reader of an icon used to work this out for itself, by a chain
    /// of negations: not in the curated symbol list, not an agent, therefore
    /// an emoji. That chain broke the moment a symbol could come from
    /// somewhere other than the curated list — the icon picker's emoji field
    /// would take `rectangle.3.group`, and the field trims to one character,
    /// so the next keystroke turned it into `r`. One exhaustive answer, in
    /// the type that already owns the contract, instead.
    enum Kind: Equatable {
        /// Nothing chosen. The renderer draws the default symbol.
        case empty

        /// A single non-ASCII grapheme — the one form the emoji field owns.
        case emoji

        /// An agent this build draws a mark for.
        case agent(CodingAgent)

        /// `agent:` followed by a name this build does not know, which is
        /// what a file written by a newer version looks like. Not a symbol:
        /// handing `agent:aider` to `Image(systemName:)` draws an empty box.
        case unknownAgent

        /// An SF Symbol name. Not checked against anything — a name this
        /// build cannot draw is still a symbol, and the caller that has to
        /// put it on screen is the one that can say whether it resolves.
        case symbol
    }

    /// Order matters: `agent:` is seven ASCII characters, so it is settled
    /// before the emoji test can look at it, and the emoji test is settled
    /// before everything left over becomes a symbol name.
    static func kind(of icon: String) -> Kind {
        if icon.isEmpty { return .empty }

        if icon.hasPrefix(agentPrefix) {
            guard let agent = agent(for: icon) else { return .unknownAgent }
            return .agent(agent)
        }

        if icon.count == 1, !(icon.unicodeScalars.first?.isASCII ?? true) { return .emoji }

        return .symbol
    }

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
