import Foundation

/// The first line a client sends after connecting, and the app's answer.
///
/// Before any MCP traffic, because two things have to be settled while there
/// is still nothing at stake: whether the two halves speak the same protocol,
/// and which terminal the caller is sitting in.
///
/// The caller *claims* a tab here and the app checks the claim against the
/// connection's peer credentials — see `MCPPeer`. A claim alone is worth
/// nothing: the tab's identity is an environment variable, and an environment
/// variable is readable by anything the reader runs.
enum MCPHandshake {
    /// Bumped when the wire format changes in a way the other half cannot
    /// ignore. The helper ships inside the app, so a mismatch means a stale
    /// process from a previous version — refused with a message that says so,
    /// rather than answered with something it will misread.
    static let version = 1

    struct Hello: Codable, Equatable {
        var version: Int

        /// The path in `GHOSTTY_TAB_STATE_FILE`, whose last component is the
        /// surface's UUID. Sent as the whole path rather than the id so the
        /// app can tell "a tab of some other Phantom" from "no tab at all".
        var tabStateFile: String?

        /// The client's own process id, so the app can walk up from it. Sent
        /// as well as read from the socket because the two disagreeing is
        /// itself worth refusing.
        var pid: Int32

        /// What the agent calls itself, for the permission sheet. Untrusted:
        /// it names the caller to the reader, and nothing is decided by it.
        var client: String?
    }

    enum Answer: Equatable {
        case accepted(surface: UUID?)
        case refused(String)
    }

    /// The app's side of the handshake, as a value so it can be tested
    /// without a socket.
    ///
    /// - Parameter peerPID: what the kernel says about the other end, not what
    ///   the message claims. Nil when the credentials could not be read at
    ///   all, which is refused: this connection can act on the reader's
    ///   terminals, and an unidentifiable caller is exactly the one to turn
    ///   away.
    static func answer(to hello: Hello, peerPID: Int32?) -> Answer {
        guard hello.version == version else {
            return .refused(
                "Phantom speaks MCP handshake v\(version) and this client speaks "
                + "v\(hello.version). It is probably left over from an earlier "
                + "version of the app; start it again.")
        }

        guard let peerPID else {
            return .refused("Phantom could not identify the process on the other end.")
        }

        guard peerPID == hello.pid else {
            return .refused(
                "The client claims to be process \(hello.pid) and the connection "
                + "belongs to \(peerPID).")
        }

        return .accepted(surface: surface(fromTabStateFile: hello.tabStateFile))
    }

    /// The surface a tab-state path names, or nil when it names none.
    ///
    /// Nil is not an error: a reader can run an agent in a terminal that is
    /// not Phantom's, and that agent may still ask questions that need no tab
    /// — listing the windows, say. It is the tools that decide what an unknown
    /// tab may do, not the handshake.
    static func surface(fromTabStateFile path: String?) -> UUID? {
        guard let path, !path.isEmpty else { return nil }
        return UUID(uuidString: (path as NSString).lastPathComponent)
    }
}
