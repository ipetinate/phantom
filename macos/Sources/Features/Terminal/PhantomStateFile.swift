import Foundation

/// Where a state store's file lives, and how state written before those
/// files were separated per build gets to where this build now looks.
///
/// The directory is the running bundle's identifier, which is the entire
/// point. The debug build is `com.ipetinate.phantom.debug` and the release
/// build is `com.ipetinate.phantom`, and three of these files named the
/// release identifier *literally* while `PhantomSessionStore` derived its own
/// from the bundle. So the two builds separated the thing that would have
/// been safe to share — a session of terminals each build opened for itself —
/// and shared everything else.
///
/// That is not a harmless duplicate. `SidebarGroupStore` keeps only the last
/// 300 entries of `tabOrder`, so a debug run spent that window on its own
/// surface ids and evicted the ordering belonging to the app the reader
/// actually uses: the release build then restored the right terminals with
/// their tabs shuffled, for no reason it could see. Observed, not theorized —
/// the debug build was caught writing `sidebar-groups.json` into the release
/// build's directory.
enum PhantomStateFile {
    /// The directory every build shared until now: the release build's
    /// identifier, spelled out. It is still the release build's directory,
    /// which is what makes this migration free for it — see `migratedURL`.
    static let legacyDirectoryName = "com.ipetinate.phantom"

    /// This build's URL for the named state file, with anything left at the
    /// shared location copied across first.
    ///
    /// For the release build the two paths are one file and nothing happens at
    /// all, deliberately: the hardcoded location this fork has always written
    /// *is* the release identifier, so the build the reader uses keeps reading
    /// the file it read yesterday and has no migration that could go wrong.
    /// Only the debug build is given somewhere new, and it starts out there
    /// holding a copy of what the two of them shared.
    ///
    /// Resolving a path is expected to be a question, not an action, and this
    /// one writes — hence the name. The alternative was a second call every
    /// store had to remember to make.
    static func migratedURL(named name: String) -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let target = base
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? legacyDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(name)

        migrate(
            from: base
                .appendingPathComponent(legacyDirectoryName, isDirectory: true)
                .appendingPathComponent(name),
            to: target
        )

        return target
    }

    /// Copies `legacy` to `target` once — only when there is something to
    /// copy and nothing already there.
    ///
    /// By copy and never by move. The original has to survive: it holds
    /// groups the reader spent months building, and if anything about the new
    /// location turns out to be wrong it is still sitting exactly where it has
    /// always been, for the release build to go on reading.
    ///
    /// Refusing to write over an existing target is the other half. A target
    /// that exists is this build's own state, which is by definition fresher
    /// than the file the two builds were sharing, and copying over it would
    /// trade a shuffled tab order for real data loss on every launch.
    ///
    /// Equal paths are turned away explicitly, though the two existence checks
    /// below already make the self-copy unreachable: when the paths are the
    /// same, the file either exists — and the second guard returns — or it does
    /// not, and the first one does. The guard is here to say that the release
    /// build is meant to do nothing, rather than to be what stops it.
    ///
    /// Past this, once, the builds have separate files and never consult each
    /// other's again: the target exists from the first save onwards, so every
    /// later launch takes an early return.
    static func migrate(from legacy: URL, to target: URL) {
        let fm = FileManager.default

        guard legacy.standardizedFileURL != target.standardizedFileURL else { return }
        guard fm.fileExists(atPath: legacy.path) else { return }
        guard !fm.fileExists(atPath: target.path) else { return }

        do {
            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.copyItem(at: legacy, to: target)
        } catch {
            /// Not fatal and not silent. A store whose file did not arrive
            /// finds nothing to load and comes up empty, which is the same
            /// state it would have had on a first launch — recoverable, and
            /// the legacy file is untouched. Saying so in the log is what
            /// separates that from state that has genuinely gone missing.
            Ghostty.logger.error(
                "state migration failed for \(target.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
