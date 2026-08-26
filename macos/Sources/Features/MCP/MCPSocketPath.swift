import Foundation

/// Where the MCP socket lives.
///
/// Beside the tab-state directory the hooks already use — `~/.cache/phantom`
/// — because the two solve the same problem: the app has to share a rendezvous
/// with processes running inside its own terminals, and those run outside
/// whatever container the app is in.
///
/// Named for the bundle, which the tab-state directory is not. That directory
/// is shared between a debug build and a release one and gets away with it:
/// its files are named by surface UUID, so two apps writing there never touch
/// the same one. A socket has no such luck — one path is one listener, and the
/// second app to start would be talking to the first one's window.
enum MCPSocketPath {
    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, including the
    /// terminator, and `bind` fails with `EINVAL` past that rather than
    /// truncating. A long bundle id or a long home directory is the way to
    /// reach it, so the limit is checked rather than assumed.
    static let maximumLength = 103

    static func url(bundleID: String, home: URL) -> URL {
        home
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("phantom", isDirectory: true)
            .appendingPathComponent("\(bundleID).sock")
    }

    static var current: URL {
        url(
            bundleID: Bundle.main.bundleIdentifier ?? "com.ipetinate.phantom",
            home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Whether a path fits in the address a Unix socket is bound with.
    static func fits(_ url: URL) -> Bool {
        url.path.utf8.count <= maximumLength
    }
}
