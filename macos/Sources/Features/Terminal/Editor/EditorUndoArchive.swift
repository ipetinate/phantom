import CryptoKit
import Foundation
import OSLog

/// The undo history on disk, so it survives quitting the app.
///
/// ## What this writes down, in plain words
///
/// A step holds the text it removed and the text it put there. Keeping steps
/// across launches therefore means writing pieces of the reader's files into
/// a folder of ours — including pieces they typed and never saved, which no
/// other part of the app copies anywhere. That is a real promise and it is
/// stated here rather than left to be discovered: the archive is the reader's
/// own text, held on their own disk, readable only by their own account.
///
/// The folder is created with `0700` and each file with `0600`. Nothing is
/// sent anywhere, and ``forget(path:)`` removes a file's archive the moment
/// its history stops being valid.
///
/// ## What makes it safe to put back
///
/// A history describes one exact text. The record therefore carries the
/// SHA-256 of the text the file held when the app last let go of it, and
/// ``load(path:matching:)`` returns nothing unless the file on disk still
/// hashes to the same thing. Edit a file in another editor, `git checkout`
/// over it, pull a branch — the archive stops matching and is dropped instead
/// of applied. This is the same rule `EditorUndoCenter` already uses in
/// memory, which is deliberate: one rule, checked in both places.
///
/// The failure this prevents is the one that must never happen. Undoing a
/// step whose offsets were computed against different text does not fail
/// loudly; it splices bytes into the middle of somebody's work, and the next
/// ⌘S writes it out.
///
/// ## Why a bad file is not an error
///
/// Every read that fails — missing, truncated, from a newer format, written
/// by a build that has since changed the shape — returns nil and, where it
/// can, deletes the file. An unreadable undo history costs the reader an undo
/// stack. Refusing to open their file because of it would cost them the file.
enum EditorUndoArchive {
    /// Bumped whenever a record written by an older build can no longer be
    /// read correctly by a newer one. Records from a different version are
    /// dropped rather than guessed at.
    static let formatVersion = 2

    /// How long a history outlives the file being closed.
    ///
    /// Fourteen days. Long enough to cover a holiday, short enough that the
    /// folder does not become a slow accumulation of everything the reader
    /// has ever opened. The fingerprint check usually gets there first: most
    /// archives die because the file changed, not because they aged out.
    static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    /// How many files keep a history on disk.
    ///
    /// Larger than `EditorUndoCenter.maximumFiles`, because disk is not
    /// memory and the point of the archive is the file you come back to on
    /// Monday. Oldest go first.
    static let maximumFiles = 128

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "undo-archive")

    struct Record: Codable {
        var version: Int

        /// The absolute path this history belongs to.
        ///
        /// Stored even though the file is named after it, because the name is
        /// a hash: this is what lets a load confirm it opened the record it
        /// meant to rather than trusting that two paths cannot collide.
        var path: String

        /// SHA-256 of the text the file held when the app let go of it.
        var fingerprint: Data

        /// Oldest first, in the order they happened.
        var steps: [CodeUndoStep]

        var written: Date
    }

    // MARK: Reading and writing

    /// Puts a file's history on disk, replacing whatever was there.
    ///
    /// An empty history writes nothing and removes any existing record: a file
    /// with nothing to undo should not leave a record of itself behind.
    static func save(path: String, fingerprint: Data, steps: [CodeUndoStep]) {
        guard !steps.isEmpty else { return forget(path: path) }
        guard let url = url(for: path) else { return }

        let record = Record(
            version: formatVersion,
            path: path,
            fingerprint: fingerprint,
            steps: steps,
            written: Date())

        do {
            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            /// Nothing to recover here and nothing to tell the reader. Failing
            /// to write an undo history is not a condition their editing
            /// should stop for.
            logger.debug("could not archive undo history: \(error.localizedDescription)")
        }
    }

    /// A file's saved history, or nil unless the text still matches it.
    ///
    /// Deletes the record whenever it turns it down, since every reason to
    /// turn one down is permanent: the text moved on, the format changed, or
    /// the bytes will not parse. None of them get better by being read again.
    static func load(path: String, matching text: String) -> [CodeUndoStep]? {
        guard let url = url(for: path),
              let data = try? Data(contentsOf: url) else { return nil }

        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == formatVersion,
              record.path == path else {
            forget(path: path)
            return nil
        }

        guard record.fingerprint == fingerprint(of: text) else {
            forget(path: path)
            return nil
        }

        guard Date().timeIntervalSince(record.written) < maximumAge else {
            forget(path: path)
            return nil
        }

        return record.steps.isEmpty ? nil : record.steps
    }

    static func forget(path: String) {
        guard let url = url(for: path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes records that aged out and, past the cap, the oldest of what is
    /// left. Called once at launch, off whatever thread will have it.
    static func prune() {
        guard let directory = directory() else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return }

        let now = Date()
        var dated: [(URL, Date)] = []
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: Set(keys)))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) >= maximumAge {
                try? FileManager.default.removeItem(at: file)
            } else {
                dated.append((file, modified))
            }
        }

        guard dated.count > maximumFiles else { return }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(dated.count - maximumFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Where it lives

    /// One file per path, named after the SHA-256 of the path.
    ///
    /// A hash rather than the path itself because a path contains separators,
    /// characters a filesystem will not take, and — often enough to matter —
    /// the name of a client or a person. Hashing keeps the folder listing from
    /// being a record of what the reader works on, which the contents already
    /// are enough of.
    static func url(for path: String) -> URL? {
        guard !path.isEmpty, let directory = directory() else { return nil }
        let name = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("\(name).json")
    }

    /// Where a test points the archive so a run does not write the machine's
    /// real history.
    ///
    /// The test bundle is hosted inside the app and shares its bundle
    /// identifier, so the two resolve to the same folder. Without this the
    /// suite wrote records into the reader's own history — measured: a full
    /// run left two files there, from suites that drive `EditorUndoCenter`
    /// and never mention the archive at all.
    ///
    /// Setting it is therefore not what keeps a test out of that folder;
    /// ``isTesting`` is. This says where a test that *wants* an archive
    /// should put one.
    static var directoryOverride: URL?

    /// Whether this process is a test run rather than the app.
    ///
    /// Read the same way `MCPServer` reads it, and used for the same reason:
    /// a test host is indistinguishable from the app by bundle identifier, so
    /// anything that writes into the reader's own state has to ask.
    private static var isTesting: Bool { MCPServer.isTesting }

    private static func directory() -> URL? {
        if let directoryOverride {
            if !FileManager.default.fileExists(atPath: directoryOverride.path) {
                try? FileManager.default.createDirectory(
                    at: directoryOverride, withIntermediateDirectories: true)
            }
            return directoryOverride
        }

        /// A test that did not ask for an archive does not get one. Answering
        /// nil here turns every entry point into a no-op, which is what a
        /// suite driving the undo center should see.
        guard !isTesting else { return nil }

        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true) else { return nil }

        let bundle = Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty"
        let directory = support
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("undo-history", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        return directory
    }

    static func fingerprint(of text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }
}
