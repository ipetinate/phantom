import Foundation
import OSLog

/// The unsaved buffer, kept so closing a file — or the app — never throws
/// away what the reader typed.
///
/// ## What changes because of this
///
/// Closing a dirty file used to ask "Save, Don't Save, Cancel", and "Don't
/// Save" meant the work was gone. Now the buffer is written down and comes
/// back the way it was left: still unsaved, still dirty, the dot still on the
/// tab. The reader decides when it goes to disk, and the editor stops making
/// them decide at the moment they are trying to do something else.
///
/// This is what VS Code calls hot exit, and the promise is the same one: the
/// editor may lose a preference, a scroll position, a window size. It may not
/// lose text somebody typed.
///
/// ## The rule for coming back
///
/// A backup is the buffer, plus the SHA-256 of what the file held on disk
/// when the backup was written. That fingerprint is not a permission to
/// restore — it is what tells the reader which situation they are in.
///
/// - **The disk is unchanged.** The ordinary case. The buffer comes back and
///   the file is dirty exactly as it was.
/// - **The disk changed while the app was closed** — a `git checkout`, a
///   pull, another editor. The buffer still comes back, because it is the
///   reader's own work and this store may not discard it. The document is
///   marked as conflicted, which is the state the editor already has for
///   "neither version can be thrown away without asking", and the reader
///   resolves it with the machinery that already exists.
///
/// The one thing never done is the quiet one: writing the buffer over a file
/// somebody else changed. Restoring makes the document dirty; only a save
/// touches the disk, and a save is the reader's own act.
///
/// ## When it is written
///
/// On a debounce while typing, so a crash costs at most a second of work; at
/// close; and at quit. It is removed the moment it stops being needed — a
/// save, a revert, or a buffer edited back to what the file already holds.
enum EditorBackupStore {
    static let folder = "unsaved"

    /// Bumped when a record written by an older build can no longer be read.
    static let formatVersion = 1

    /// How long an unsaved buffer is kept for a file nobody comes back to.
    ///
    /// Ninety days, far longer than the undo history's fourteen. The two are
    /// not the same kind of thing: a forgotten undo stack costs an undo, and a
    /// forgotten buffer costs the writing itself. Erring long is cheap — the
    /// records are text — and erring short is not recoverable.
    static let maximumAge: TimeInterval = 90 * 24 * 60 * 60

    /// How many unsaved buffers are kept at once. Generous for the same
    /// reason the age is.
    static let maximumFiles = 512

    /// The largest buffer written down.
    ///
    /// Eight megabytes. Past that the write itself becomes something the
    /// reader would feel on every debounce, and a file that size is not one
    /// being typed into. A buffer over the cap is not backed up, and the
    /// document keeps the behaviour it had before this existed: it asks
    /// before closing.
    static let maximumBytes = 8 * 1024 * 1024

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "editor-backup")

    struct Record: Codable {
        var version: Int
        var path: String

        /// SHA-256 of what the file held on disk when this was written.
        var diskFingerprint: Data

        /// The buffer, as the reader left it.
        var text: String

        var written: Date
    }

    /// What a restored backup means for the document taking it.
    struct Restored {
        let text: String

        /// True when the file on disk is no longer what it was when the
        /// buffer was written down, so the two versions have to be resolved.
        let conflictsWithDisk: Bool
    }

    // MARK: Writing

    /// Writes `text` down as the unsaved buffer for `path`.
    ///
    /// `diskText` is what the file holds now — the comparison the caller has
    /// already made to know the buffer is dirty, passed in rather than read
    /// again.
    static func save(path: String, text: String, diskText: String) {
        guard text != diskText else { return forget(path: path) }
        guard text.utf8.count <= maximumBytes else { return forget(path: path) }
        guard let url = EditorStateFolder.fileURL(for: path, in: folder) else { return }

        let record = Record(
            version: formatVersion,
            path: path,
            diskFingerprint: EditorStateFolder.fingerprint(of: diskText),
            text: text,
            written: Date())

        do {
            try EditorStateFolder.write(try JSONEncoder().encode(record), to: url)
        } catch {
            /// Reported and not raised. A backup that cannot be written is
            /// worth knowing about in a log; it is not worth interrupting
            /// somebody's typing for, and the file itself is untouched.
            logger.error("could not write unsaved buffer: \(error.localizedDescription)")
        }
    }

    // MARK: Reading

    /// The unsaved buffer for `path`, or nil when there is none to put back.
    ///
    /// `diskText` is what the file holds now, so this can say whether the two
    /// have diverged. Note what is *not* here: no branch returns nil because
    /// the disk moved. Divergence is reported, never resolved by discarding.
    static func load(path: String, diskText: String) -> Restored? {
        guard let url = EditorStateFolder.fileURL(for: path, in: folder),
              let data = try? Data(contentsOf: url) else { return nil }

        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == formatVersion,
              record.path == path else {
            forget(path: path)
            return nil
        }

        /// The buffer caught up with the file while the app was closed —
        /// somebody saved the same text elsewhere. There is nothing unsaved
        /// left to restore, so the record goes.
        guard record.text != diskText else {
            forget(path: path)
            return nil
        }

        return Restored(
            text: record.text,
            conflictsWithDisk: record.diskFingerprint != EditorStateFolder.fingerprint(of: diskText))
    }

    /// Whether a file has unsaved work waiting, without reading it back.
    ///
    /// For the close path, which has to know whether letting go of a document
    /// is safe before it does.
    static func hasBackup(path: String) -> Bool {
        guard let url = EditorStateFolder.fileURL(for: path, in: folder) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func forget(path: String) {
        EditorStateFolder.remove(at: EditorStateFolder.fileURL(for: path, in: folder))
    }

    /// Follows a file that was renamed, so the buffer moves with it.
    static func repath(from oldPath: String, to newPath: String) {
        guard oldPath != newPath,
              let old = EditorStateFolder.fileURL(for: oldPath, in: folder),
              let data = try? Data(contentsOf: old),
              var record = try? JSONDecoder().decode(Record.self, from: data),
              let new = EditorStateFolder.fileURL(for: newPath, in: folder)
        else { return }

        record.path = newPath
        try? EditorStateFolder.write(try JSONEncoder().encode(record), to: new)
        EditorStateFolder.remove(at: old)
    }

    static func prune() {
        EditorStateFolder.prune(folder, maximumAge: maximumAge, maximumFiles: maximumFiles)
    }
}
