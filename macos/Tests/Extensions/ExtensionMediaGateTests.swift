import Foundation
@testable import Ghostty
import Testing

struct ExtensionMediaGateTests {
    private func media(_ path: String, _ bytes: Int) -> ExtensionCard.Media {
        ExtensionCard.Media(path: path, bytes: bytes)
    }

    @Test func classifiesBySuffixRegardlessOfCase() {
        #expect(ExtensionMediaGate.kind(ofPath: "media/a.png") == .image)
        #expect(ExtensionMediaGate.kind(ofPath: "media/a.JPG") == .image)
        #expect(ExtensionMediaGate.kind(ofPath: "media/a.jpeg") == .image)
        #expect(ExtensionMediaGate.kind(ofPath: "media/a.webp") == .image)
        #expect(ExtensionMediaGate.kind(ofPath: "media/a.gif") == .animation)
        #expect(ExtensionMediaGate.kind(ofPath: "media/a.mp4") == .video)
        #expect(ExtensionMediaGate.kind(ofPath: "media/a.webm") == .video)
        #expect(ExtensionMediaGate.kind(ofPath: "media/icon.svg") == .image)
        #expect(ExtensionMediaGate.kind(ofPath: "media/a.pdf") == nil)
        #expect(ExtensionMediaGate.kind(ofPath: "media/a") == nil)
        #expect(ExtensionMediaGate.kind(ofPath: "media/a.png.exe") == nil)
    }

    @Test func eachKindHasItsOwnCeiling() {
        #expect(ExtensionMediaGate.limit(for: .image) == 2 * 1024 * 1024)
        #expect(ExtensionMediaGate.limit(for: .animation) == 5 * 1024 * 1024)
        #expect(ExtensionMediaGate.limit(for: .video) == 12 * 1024 * 1024)
        #expect(ExtensionMediaGate.maxTotalBytes == 24 * 1024 * 1024)
        #expect(ExtensionMediaGate.maxFiles == 32)
        #expect(ExtensionMediaGate.maxDocumentBytes == 256 * 1024)
    }

    @Test func aListWithinEveryBudgetPasses() {
        let list = [
            media("media/icon.svg", 900),
            media("media/cover.png", ExtensionMediaGate.maxImageBytes),
            media("media/demo.gif", ExtensionMediaGate.maxAnimationBytes),
            media("media/demo.mp4", ExtensionMediaGate.maxVideoBytes),
        ]
        #expect(ExtensionMediaGate.violation(media: list) == nil)
        #expect(ExtensionMediaGate.violation(media: []) == nil)
    }

    @Test func namesTheFirstFileOverItsCeiling() {
        let list = [media("media/a.png", 10), media("media/b.gif", ExtensionMediaGate.maxAnimationBytes + 1)]
        #expect(
            ExtensionMediaGate.violation(media: list)
                == .oversized("media/b.gif", bytes: ExtensionMediaGate.maxAnimationBytes + 1, limit: ExtensionMediaGate.maxAnimationBytes))
        #expect(
            ExtensionMediaGate.violation(media: [media("media/a.png", -1)])
                == .oversized("media/a.png", bytes: -1, limit: ExtensionMediaGate.maxImageBytes))
    }

    @Test func anSVGIsAnImageWithTheImageCeiling() {
        #expect(ExtensionMediaGate.violation(media: [media("media/icon.svg", 100), media("media/logo.svg", 10)]) == nil)
        #expect(
            ExtensionMediaGate.violation(media: [media("media/icon.svg", ExtensionMediaGate.maxImageBytes + 1)])
                == .oversized("media/icon.svg", bytes: ExtensionMediaGate.maxImageBytes + 1, limit: ExtensionMediaGate.maxImageBytes))
    }

    @Test func anUnknownSuffixIsRefused() {
        let list = [media("media/a.png", 10), media("media/notes.txt", 10)]
        #expect(ExtensionMediaGate.violation(media: list) == .unknownKind("media/notes.txt"))
    }

    @Test func theCountAndTheTotalAreBounded() {
        let many = (0...ExtensionMediaGate.maxFiles).map { media("media/\($0).png", 1) }
        #expect(ExtensionMediaGate.violation(media: many) == .tooManyFiles(ExtensionMediaGate.maxFiles + 1))

        let heavy = (0..<13).map { media("media/\($0).png", ExtensionMediaGate.maxImageBytes) }
        #expect(ExtensionMediaGate.violation(media: heavy) == .totalOversized(13 * ExtensionMediaGate.maxImageBytes))
    }

    @Test func messagesEscapeAndBoundThePath() {
        let violation = ExtensionMediaGate.Violation.unknownKind("media/bidi\u{202E}.bin")
        #expect(violation.message.contains("media/bidi\\u{202E}.bin"))
        #expect(!violation.message.unicodeScalars.contains("\u{202E}"))
    }

    // MARK: On disk

    private func makeExtension(files: [String: Int]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-media-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, bytes) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
        }
        return root
    }

    @Test func aDirectoryWithoutMediaPasses() throws {
        let root = try makeExtension(files: ["extension.json": 40, "extension.mdx": 400, "icons/lua.svg": 300])
        defer { try? FileManager.default.removeItem(at: root) }

        try ExtensionMediaGate.check(directory: root)
    }

    @Test func listsTheMediaFolderRelativeToTheExtension() throws {
        let root = try makeExtension(files: [
            "media/cover.png": 10, "media/nested/shot.webp": 20, "media/icon.svg": 5, "icons/lua.svg": 300,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let listing = try ExtensionMediaGate.listing(of: root.appendingPathComponent("media"))
        #expect(listing == [
            ExtensionCard.Media(path: "media/cover.png", bytes: 10),
            ExtensionCard.Media(path: "media/icon.svg", bytes: 5),
            ExtensionCard.Media(path: "media/nested/shot.webp", bytes: 20),
        ])
        try ExtensionMediaGate.check(directory: root)
    }

    @Test func anOversizedFileOnDiskIsCaught() throws {
        let root = try makeExtension(files: ["media/cover.png": ExtensionMediaGate.maxImageBytes + 1])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: ExtensionMediaGate.Violation.oversized(
            "media/cover.png", bytes: ExtensionMediaGate.maxImageBytes + 1, limit: ExtensionMediaGate.maxImageBytes)
        ) {
            try ExtensionMediaGate.check(directory: root)
        }
    }

    @Test func anUnknownFileTypeOnDiskIsCaught() throws {
        let root = try makeExtension(files: ["media/cover.png": 10, "media/notes.bin": 10])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: ExtensionMediaGate.Violation.unknownKind("media/notes.bin")) {
            try ExtensionMediaGate.check(directory: root)
        }
    }

    @Test func anOversizedDocumentIsCaught() throws {
        let root = try makeExtension(files: ["extension.mdx": ExtensionMediaGate.maxDocumentBytes + 1])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: ExtensionMediaGate.Violation.documentOversized(ExtensionMediaGate.maxDocumentBytes + 1)) {
            try ExtensionMediaGate.check(directory: root)
        }
    }
}
