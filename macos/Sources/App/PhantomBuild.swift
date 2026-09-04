import Foundation

/// Which build of Phantom is running, and what that build may call its own
/// files.
///
/// Two builds of this app are routinely installed at once — the one in
/// `/Applications` and the one a developer just built — and the fork has had to
/// learn, one leak at a time, that everything either of them writes has to
/// carry the build's name. `PhantomStateFile` learned it for the session and
/// the sidebar groups, `MCPSocketPath` and `MCPServerCommand` for the socket
/// and the agent entry, `GuiConfigStore` for the configuration directory.
///
/// The last leak was the hook scripts, which are the worst of the set: they do
/// not live in this app's own storage at all. `~/.claude/hooks/…` belongs to
/// Claude Code, so both builds wrote one file at one path and registered it
/// once — each launch rewriting it with its own text, and an uninstall from
/// either taking the other's hooks with it.
///
/// This is that rule, in one place, so the next thing anybody writes outside
/// this app can ask instead of guessing.
enum PhantomBuild {
    /// The release build's identifier. Everything else is a variant of it.
    static let releaseBundleID = "com.ipetinate.phantom"

    /// The base name every build shares, and the first word of every file this
    /// app writes into somebody else's directory.
    static let baseName = "phantom"

    /// What marks this build apart, or nil for the release build.
    ///
    /// The suffix comes off the bundle id, which is the same rule
    /// `MCPServerCommand.name(forBundleID:)` uses for the socket and the agent
    /// entry: `com.ipetinate.phantom` is the release build and answers nil,
    /// `com.ipetinate.phantom.debug` answers `debug`.
    static func variant(forBundleID id: String) -> String? {
        guard let last = id.split(separator: ".").last,
              !last.isEmpty,
              last.lowercased() != baseName
        else { return nil }
        return last.lowercased()
    }

    static var variant: String? {
        variant(forBundleID: Bundle.main.bundleIdentifier ?? releaseBundleID)
    }

    static var isRelease: Bool { variant == nil }

    /// The name this build gives a file the release build calls `releaseName`.
    ///
    /// The leading `phantom` becomes this build's own name, so
    /// `phantom-tab-state.sh` is `phantom-debug-tab-state.sh` for the debug
    /// build and unchanged for the release one. Unchanged is the point: the
    /// release build keeps every path it has ever written, so a reader's
    /// installed hooks are not touched by any of this.
    ///
    /// A name that does not begin with `phantom` comes back as it went in.
    /// There is one — `ghostty-tab-state.sh`, from before the fork was renamed
    /// — and it belongs to the release build's history, not to a variant's.
    static func fileName(_ releaseName: String, forBundleID id: String) -> String {
        guard let variant = variant(forBundleID: id),
              releaseName.hasPrefix(baseName)
        else { return releaseName }
        return "\(baseName)-\(variant)" + releaseName.dropFirst(baseName.count)
    }

    static func fileName(_ releaseName: String) -> String {
        fileName(releaseName, forBundleID: Bundle.main.bundleIdentifier ?? releaseBundleID)
    }
}
