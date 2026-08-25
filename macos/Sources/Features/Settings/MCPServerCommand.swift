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
    /// their agent's own output, so it is the app's name and not an internal
    /// one — the same name `MCPService.serverName` answers `initialize` with.
    static let name = MCPService.serverName

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
    static let arguments: [String] = [action]
}
