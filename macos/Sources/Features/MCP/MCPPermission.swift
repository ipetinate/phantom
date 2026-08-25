import Foundation

/// What a client is allowed to reach, and for how long.
///
/// The agent **asks** and the reader grants. There is deliberately no tool
/// that grants: an agent able to widen its own reach would ask for everything
/// on its first call and nobody would ever be consulted again, which is
/// consent as decoration.
///
/// A value with no window and no store in it, so every rule here is testable
/// without either.
enum MCPPermission {
    /// How far a grant reaches.
    ///
    /// Ordered from narrow to wide, and that order is load-bearing: a grant
    /// covers a request when it is at least as wide, so `all` answers for a
    /// tab without anyone writing that rule twice.
    enum Scope: String, Codable, CaseIterable, Comparable {
        case tab
        case group
        case all

        var reach: Int {
            switch self {
            case .tab: return 0
            case .group: return 1
            case .all: return 2
            }
        }

        static func < (lhs: Scope, rhs: Scope) -> Bool { lhs.reach < rhs.reach }
    }

    /// What is being asked for. Kept apart from the scope because the two
    /// answer different questions — *how much* and *what for* — and folding
    /// them together is how a grant to read ends up allowing a command.
    enum Capability: String, Codable, CaseIterable {
        /// Read a terminal's scrollback. The most sensitive thing this app
        /// holds: keys, tokens, production output.
        case read

        /// Type into an idle terminal. The most dangerous, which is why the
        /// idle rule sits on top of the grant rather than instead of it.
        case run

        var title: String {
            switch self {
            case .read: return "read this terminal"
            case .run: return "run commands in this terminal"
            }
        }
    }

    /// One thing the reader granted.
    struct Grant: Codable, Equatable {
        var capability: Capability
        var scope: Scope

        /// The tab the grant was made from, which is what a `tab` or `group`
        /// scope is measured against. Nil for `all`, which needs no anchor.
        var surface: UUID?

        /// The group the anchoring tab was in when the grant was made.
        /// Resolved once, at grant time: a tab that moves to another group
        /// later must not carry the old group's permission with it.
        var group: String?
    }

    /// One question, as the tools ask it.
    struct Request: Equatable {
        var capability: Capability

        /// The tab being reached *for*, which is not the caller's own tab: an
        /// agent in tab A asking to read tab B is the case the scopes exist
        /// for.
        var surface: UUID?
        var group: String?
    }

    /// Whether a set of grants answers a request.
    ///
    /// A grant answers when it is for the same capability and reaches at
    /// least as far. `all` reaches everything; `group` reaches a tab in the
    /// same group, which is why the request carries the target's group rather
    /// than leaving the caller to claim one; `tab` reaches exactly one.
    static func isAllowed(_ request: Request, by grants: [Grant]) -> Bool {
        grants.contains { grant in
            guard grant.capability == request.capability else { return false }

            switch grant.scope {
            case .all:
                return true
            case .group:
                guard let granted = grant.group, let asked = request.group else { return false }
                return granted == asked
            case .tab:
                guard let granted = grant.surface, let asked = request.surface else { return false }
                return granted == asked
            }
        }
    }

    /// What the sheet says, in the reader's words rather than the protocol's.
    ///
    /// Built here so the sentence is the same wherever it is shown, and so it
    /// can be asserted: a prompt that names the wrong tab is worse than no
    /// prompt at all.
    static func question(
        client: String?,
        capability: Capability,
        tabTitle: String?
    ) -> String {
        let who = client.map { "“\($0)”" } ?? "An agent"
        let what = capability.title
        guard let tabTitle else { return "\(who) wants to \(what)." }
        return "\(who) wants to \(what.replacingOccurrences(of: "this terminal", with: "“\(tabTitle)”"))."
    }
}
