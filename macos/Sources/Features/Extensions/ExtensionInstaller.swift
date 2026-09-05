import CryptoKit
import Foundation

enum ExtensionInstaller {
    enum Failure: Error, Equatable {
        case invalidIdentifier
        case download(String)
        case httpStatus(Int)
        case sizeMismatch(received: Int, expected: Int)
        case digestMismatch
        case unreadableArchive(String)
        case unsafeEntry(ExtensionArchive.EntryRejection)
        case noManifest
        case symbolicLink(String)
        case unexpectedItem(String)
        case manifestMismatch(id: String, version: String)
        case extraction(String)
        case replace(String)
        case removal(String)
        case missingOnDisk
        case outsideExtensionsDirectory

        var message: String {
            switch self {
            case .invalidIdentifier:
                return "The extension's id is not one this app can install."
            case .download(let reason):
                return "The download failed: \(reason)"
            case .httpStatus(let code):
                return "The download failed: the server answered \(code)."
            case .sizeMismatch(let received, let expected):
                return "The download was \(received) bytes; the registry lists \(expected)."
            case .digestMismatch:
                return "The download does not match the registry's checksum."
            case .unreadableArchive(let reason):
                return "The archive could not be read: \(reason)"
            case .unsafeEntry(let rejection):
                return rejection.message
            case .noManifest:
                return "The archive has no \(ExtensionArchive.manifestFileName) at its root."
            case .symbolicLink(let path):
                return "The archive contains a symbolic link: \(ExtensionArchive.shown(path))."
            case .unexpectedItem(let path):
                return "The archive contains something that is neither a file nor a folder: \(ExtensionArchive.shown(path))."
            case .manifestMismatch(let id, let version):
                return "The archive's manifest says \(id) \(version), which is not what the registry lists."
            case .extraction(let reason):
                return "The archive could not be extracted: \(reason)"
            case .replace(let reason):
                return "The extension could not be moved into place: \(reason)"
            case .removal(let reason):
                return "The extension could not be removed: \(reason)"
            case .missingOnDisk:
                return "The extension is no longer on disk."
            case .outsideExtensionsDirectory:
                return "The extension's folder is not inside the extensions directory, so it was left alone."
            }
        }
    }

    static let chunkBytes = 64 * 1024
    static let hashChunkBytes = 1 << 20
    static let downloadIdleTimeout: TimeInterval = 30
    static let processTimeout: TimeInterval = 60

    static func install(
        _ entry: ExtensionIndex.Entry,
        into extensionsDir: URL,
        progress: @escaping @MainActor @Sendable (ExtensionActivity) -> Void
    ) async throws {
        guard LanguageManifest.validID(entry.id) == entry.id else { throw Failure.invalidIdentifier }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-extension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let archive = scratch.appendingPathComponent("\(entry.id)-\(entry.version).zip")
        try await fetch(entry, to: archive, progress: progress)

        await progress(.verifying)
        let staged = scratch.appendingPathComponent("extracted", isDirectory: true)
        try await stage(archive: archive, expecting: entry, into: staged)

        await progress(.installing)
        try install(from: staged, as: entry, into: extensionsDir)
    }

    static func stage(archive: URL, expecting entry: ExtensionIndex.Entry, into destination: URL) async throws {
        try verify(archive, against: entry)
        try await extract(archive, into: destination, expecting: entry)
    }

    static func install(from staged: URL, as entry: ExtensionIndex.Entry, into extensionsDir: URL) throws {
        guard LanguageManifest.validID(entry.id) == entry.id else { throw Failure.invalidIdentifier }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: extensionsDir, withIntermediateDirectories: true)
        } catch {
            throw Failure.replace(error.localizedDescription)
        }

        let copy = extensionsDir.appendingPathComponent(".\(entry.id).staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.copyItem(at: staged, to: copy)
        } catch {
            try? fileManager.removeItem(at: copy)
            throw Failure.replace(error.localizedDescription)
        }

        do {
            try replace(extensionsDir.appendingPathComponent(entry.id, isDirectory: true), with: copy, in: extensionsDir)
        } catch {
            try? fileManager.removeItem(at: copy)
            throw error
        }
    }

    static func remove(at candidate: URL, in extensionsDir: URL) throws {
        guard exists(candidate) else { throw Failure.missingOnDisk }
        let root = extensionsDir.standardizedFileURL.resolvingSymlinksInPath().path
        let target = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        guard ExtensionArchive.isContained(path: target, inDirectory: root) else {
            throw Failure.outsideExtensionsDirectory
        }
        do {
            try FileManager.default.removeItem(at: candidate)
        } catch {
            throw Failure.removal(error.localizedDescription)
        }
    }

    // MARK: Download

    static func fetch(
        _ entry: ExtensionIndex.Entry,
        to file: URL,
        progress: @escaping @MainActor @Sendable (ExtensionActivity) -> Void
    ) async throws {
        do {
            try await stream(entry, to: file, progress: progress)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.download(error.localizedDescription)
        }
    }

    private static func stream(
        _ entry: ExtensionIndex.Entry,
        to file: URL,
        progress: @escaping @MainActor @Sendable (ExtensionActivity) -> Void
    ) async throws {
        let request = URLRequest(
            url: entry.downloadURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: downloadIdleTimeout
        )
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.download("the server did not answer over HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else { throw Failure.httpStatus(http.statusCode) }

        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw Failure.download("a temporary file could not be created.")
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let expected = entry.bytes
        var received = 0
        var lastReported = 0.0
        var buffer = Data(capacity: chunkBytes)

        for try await byte in bytes {
            buffer.append(byte)
            guard buffer.count == chunkBytes else { continue }

            received += buffer.count
            guard received <= expected else {
                throw Failure.sizeMismatch(received: received, expected: expected)
            }
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)

            let fraction = Double(received) / Double(expected)
            if fraction - lastReported >= 0.01 {
                lastReported = fraction
                await progress(.downloading(fraction: fraction))
            }
        }

        if !buffer.isEmpty {
            received += buffer.count
            try handle.write(contentsOf: buffer)
        }
        try handle.close()

        guard received == expected else {
            throw Failure.sizeMismatch(received: received, expected: expected)
        }
    }

    // MARK: Verification

    static func verify(_ file: URL, against entry: ExtensionIndex.Entry) throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        guard size == entry.bytes else {
            throw Failure.sizeMismatch(received: size, expected: entry.bytes)
        }
        guard try digest(of: file) == entry.sha256 else { throw Failure.digestMismatch }
    }

    static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: hashChunkBytes), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Extraction

    private static func extract(
        _ archive: URL,
        into destination: URL,
        expecting entry: ExtensionIndex.Entry
    ) async throws {
        let listing = await run("/usr/bin/unzip", ["-Z1", archive.path])
        guard listing.succeeded else { throw Failure.unreadableArchive(listing.message) }

        let entries = ExtensionArchive.entries(fromListing: listing.stdout)
        if let rejection = ExtensionArchive.firstRejection(in: entries) {
            throw Failure.unsafeEntry(rejection)
        }
        guard ExtensionArchive.hasManifestAtRoot(entries) else { throw Failure.noManifest }

        let extraction = await run("/usr/bin/ditto", ["-x", "-k", archive.path, destination.path])
        guard extraction.succeeded else { throw Failure.extraction(extraction.message) }

        try inspect(destination)

        guard let manifest = LanguageManifest.load(directory: destination, scope: .user) else {
            throw Failure.noManifest
        }
        guard manifest.id == entry.id, manifest.version == entry.version else {
            throw Failure.manifestMismatch(id: manifest.listIdentity, version: manifest.version)
        }
    }

    private static func run(_ launchPath: String, _ arguments: [String]) async -> ShellCommand.Result {
        await Task.detached(priority: .utility) {
            ShellCommand.runResult(launchPath, arguments, timeout: processTimeout)
        }.value
    }

    static func inspect(_ root: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { throw Failure.extraction("the extracted files could not be listed.") }

        let prefixLength = root.path.count + 1
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: keys)
            let relative = String(item.path.dropFirst(prefixLength))
            if values.isSymbolicLink == true { throw Failure.symbolicLink(relative) }
            guard values.isRegularFile == true || values.isDirectory == true else {
                throw Failure.unexpectedItem(relative)
            }
        }
    }

    // MARK: Replacement

    private static func replace(_ target: URL, with staged: URL, in extensionsDir: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: extensionsDir, withIntermediateDirectories: true)
        } catch {
            throw Failure.replace(error.localizedDescription)
        }

        let aside = extensionsDir.appendingPathComponent(
            ".\(target.lastPathComponent).replaced-\(UUID().uuidString)",
            isDirectory: true
        )
        let hadPrevious = exists(target)
        if hadPrevious {
            do {
                try fileManager.moveItem(at: target, to: aside)
            } catch {
                throw Failure.replace(error.localizedDescription)
            }
        }

        do {
            try fileManager.moveItem(at: staged, to: target)
        } catch {
            if hadPrevious { try? fileManager.moveItem(at: aside, to: target) }
            throw Failure.replace(error.localizedDescription)
        }

        if hadPrevious { try? fileManager.removeItem(at: aside) }
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
