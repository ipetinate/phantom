import Foundation

/// The half of an MCP registration that three of the four agents share: a JSON
/// file holding a map of named servers, in which Phantom owns exactly one name.
///
/// Written once rather than three times because the risk is identical in all
/// three and it is not a small one. Every file these installers touch belongs
/// to somebody else — `~/.claude.json` holds the reader's sign-in session and
/// every project they have ever trusted, `opencode.json` holds their model and
/// provider settings — so the operation is always "replace one key, copy the
/// rest", never "write out what Phantom knows about".
///
/// The one agent left out is Codex, whose configuration is TOML. See
/// `TOMLMCPInstaller` for why that one cannot share this and what it does
/// instead.
enum MCPConfigFile {
    /// Reads a configuration, telling "there is nothing here yet" apart from
    /// "there is something here this does not understand".
    ///
    /// An empty dictionary means the file is absent or empty, which an
    /// installer may safely create. Nil means a file exists that is not a JSON
    /// object — hand-edited, half-written, a top-level array — and the
    /// installer must leave it alone. `JSONHooksInstaller.readSettings(at:)`
    /// draws the same distinction and gives the same reason: collapsing the two
    /// is what turns one malformed byte into the atomic replacement of
    /// everything the reader had.
    static func read(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? nil : [:]
        }
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Writes it back, temp file first and then a rename.
    ///
    /// That is what `.atomic` does, and it is the only acceptable shape here: a
    /// truncate-then-write interrupted halfway through `~/.claude.json` costs
    /// the reader their sign-in session, and there is no copy of it anywhere.
    static func write(_ config: [String: Any], to url: URL) -> Bool {
        guard JSONSerialization.isValidJSONObject(config),
              let data = try? JSONSerialization.data(
                withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        else { return false }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: Owning one name

    /// The entry stored under `name`, or nil when there is none.
    static func entry(
        named name: String, under key: String, in config: [String: Any]?
    ) -> [String: Any]? {
        (config?[key] as? [String: Any])?[name] as? [String: Any]
    }

    /// Whether the entry under `name` is the one this build would write.
    ///
    /// Equality rather than "the key is present", because the command in it is
    /// a path to this bundle and the bundle moves. A reader who drags Phantom
    /// from `~/Downloads` to `/Applications` leaves four agents pointing at a
    /// path that no longer resolves, and nothing about that failure names
    /// Phantom — the agent simply reports that a server would not start.
    static func matches(
        _ entry: [String: Any], named name: String, under key: String, in config: [String: Any]?
    ) -> Bool {
        guard let found = self.entry(named: name, under: key, in: config) else { return false }
        return (found as NSDictionary) == (entry as NSDictionary)
    }

    /// Puts `entry` under `name`, leaving every other server and every other
    /// top-level key exactly where it was.
    static func merged(
        _ entry: [String: Any], named name: String, under key: String, into config: [String: Any]
    ) -> [String: Any] {
        var config = config
        var servers = config[key] as? [String: Any] ?? [:]
        servers[name] = entry
        config[key] = servers
        return config
    }

    /// Takes `name` out again.
    ///
    /// The map itself stays, even when it empties. Removing it would be a
    /// second change the reader did not ask for, and an agent reading an absent
    /// key and an empty one arrives at the same place.
    static func removed(
        named name: String, under key: String, from config: [String: Any]
    ) -> [String: Any] {
        guard var servers = config[key] as? [String: Any] else { return config }
        var config = config
        servers.removeValue(forKey: name)
        config[key] = servers
        return config
    }

    /// Whether a rewrite kept everything it was not asked to change.
    ///
    /// Read back off disk after every write, because these files are shared
    /// with the agent that owns them and a serialization this app got wrong
    /// would be invisible otherwise. `~/.claude.json` is the reason it is worth
    /// the read: it is around a hundred kilobytes of state Phantom did not
    /// write and cannot reconstruct.
    static func preserves(_ before: [String: Any], in after: [String: Any]?) -> Bool {
        guard let after else { return false }
        return before.keys.allSatisfy { after[$0] != nil }
    }
}
