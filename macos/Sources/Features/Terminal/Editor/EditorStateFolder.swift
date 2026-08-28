import CryptoKit
import Foundation

/// Where the editor keeps what it knows about a file between launches.
///
/// Two things live here and they are held to the same rules, which is the
/// reason this type exists rather than each carrying its own copy: the undo
/// history (``EditorUndoArchive``) and the unsaved buffer
/// (``EditorBackupStore``). Both hold the reader's own text, including text
/// they never saved, and the protections around that must not be able to
/// drift apart.
///
/// The rules:
///
/// - The folder is `0700` and every file in it is `0600`. Nothing is sent
///   anywhere.
/// - A file is named after the SHA-256 of its path. A path contains
///   separators, characters a filesystem will not take, and — often enough
///   to matter — the name of a client or a person. Hashing keeps the folder
///   listing from being a record of what the reader works on, which the
///   contents already are enough of.
/// - Under a test host, every lookup answers nil unless the test names a
///   folder of its own. The test bundle runs inside the app and shares its
///   bundle identifier, so without this the suite writes into the reader's
///   own state. It did: a full run once left two undo records there.
enum EditorStateFolder {
    /// Where a test points the whole family, so a run does not touch the real
    /// one. Each subfolder is still made underneath it.
    static var override: URL?

    /// Whether this process is a test host rather than the app.
    static var isTesting: Bool { MCPServer.isTesting }

    /// One named subfolder, made if it is not there.
    static func directory(named name: String) -> URL? {
        if let override {
            let directory = override.appendingPathComponent(name, isDirectory: true)
            create(directory)
            return directory
        }

        guard !isTesting else { return nil }

        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true) else { return nil }

        let bundle = Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty"
        let directory = support
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        create(directory)
        return directory
    }

    /// The file holding what is known about `path`, inside `folder`.
    static func fileURL(for path: String, in folder: String) -> URL? {
        guard !path.isEmpty, let directory = directory(named: folder) else { return nil }
        return directory.appendingPathComponent("\(digest(of: path)).json")
    }

    /// Writes `data` so a reader either sees the whole of it or the version
    /// before it, and so nobody else can read it at all.
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// SHA-256, hex.
    static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 as bytes, for the fingerprints stored inside a record.
    static func fingerprint(of text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }

    /// Removes records older than `maximumAge`, then the oldest of what is
    /// left once there are more than `maximumFiles`.
    static func prune(_ folder: String, maximumAge: TimeInterval, maximumFiles: Int) {
        guard let directory = directory(named: folder) else { return }
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

    private static func create(_ directory: URL) {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
