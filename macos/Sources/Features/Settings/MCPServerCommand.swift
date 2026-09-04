import Foundation

/// The command an agent runs to reach this Phantom.
///
/// The app's own binary with a CLI action, rather than a helper of its own:
/// the bundle is already signed, already on disk wherever the reader put it,
/// and already knows the socket path — a second executable would have to be
/// taught all three and kept in step with them.
///
/// Resolved from the running bundle rather than written down, for the reason
/// `MCPService.appVersion` is read from the bundle: a path spelled here would
/// name `/Applications` and be wrong for everybody who runs a build out of
/// `~/Downloads`, out of a worktree, or beside a release copy. It is also why
/// the entry has to be repaired rather than installed once — an app that moved
/// leaves every agent pointing at nothing.
@MainActor
enum MCPServerCommand {
    /// The name each agent lists the server under. The reader sees this in
    /// their agent's own output, so it starts from the app's name rather than
    /// an internal one — the same name `MCPService.serverName` answers
    /// `initialize` with.
    ///
    /// **Suffixed per build, and that is the whole point.** A debug build and a
    /// release build have different bundle ids and so different sockets — which
    /// is one of the reasons a socket was chosen over a port — but they used to
    /// write the *same* entry name into the same user-scope configuration,
    /// each pointing at its own bundle. With both installed, whichever launched
    /// last repaired the shared entry to itself, so the agent silently followed
    /// the build the reader happened to open most recently. Nothing about that
    /// looks like a fault: the server connects, answers, and lists tools for
    /// the wrong set of windows.
    ///
    /// The suffix comes off the bundle id, so the rule matches the socket's
    /// exactly rather than being a second convention that agrees today:
    /// `com.ipetinate.phantom` stays `phantom`, `com.ipetinate.phantom.debug`
    /// becomes `phantom-debug`.
    static var name: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        return name(forBundleID: id)
    }

    /// The rule itself, without a bundle, so it can be asserted.
    static func name(forBundleID id: String) -> String {
        let base = MCPService.serverName
        guard let variant = id.split(separator: ".").last,
              !variant.isEmpty,
              variant.lowercased() != base
        else { return base }
        return "\(base)-\(variant.lowercased())"
    }

    /// The CLI action. Written here as the single spelling of it, so the four
    /// installers cannot come to disagree about the word.
    static let action = "+mcp-server"

    /// `<bundle>/Contents/MacOS/ghostty`. Nil is not expected — a running app
    /// has an executable — but it is the only honest answer if the bundle is
    /// ever asked before it exists, and every caller refuses to write rather
    /// than registering a command with an empty path.
    static var executablePath: String? {
        Bundle.main.executableURL?.path
    }

    /// Never folded into the command as one string. All four agents take the
    /// program and its arguments apart, which is what keeps a bundle living in
    /// a directory with a space in its name out of the quoting business
    /// entirely.
    ///
    /// **The socket is named here, and that is not belt and braces.** The
    /// client resolves it from `PHANTOM_MCP_SOCKET`, which every Phantom
    /// exports into the terminals it opens — so an agent started from a
    /// release terminal reaches the release app *whichever binary the entry
    /// names*. The entry called `phantom-debug`, pointing at the debug build's
    /// own executable, then answers for the release build's windows: it opens
    /// files in them, lists their terminals, and nothing anywhere says so.
    ///
    /// Measured, not theorised — it is how a debug build under test came to be
    /// opening files in the reader's working app. The name, the binary and the
    /// socket all have to agree, and this is the one of the three that was
    /// left to the environment.
    static var arguments: [String] { [action, "--socket=\(MCPSocketPath.current.path)"] }
}
