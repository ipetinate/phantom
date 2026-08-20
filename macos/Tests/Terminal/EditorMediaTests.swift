import AppKit
import Foundation
import PDFKit
@testable import Ghostty
import Testing

/// Which files the editor shows instead of letting you edit.
struct EditorMediaKindTests {
    private func kind(_ name: String) -> EditorMediaKind? {
        EditorMediaKind.resolve(fileName: name)
    }

    @Test func everyImageExtensionResolvesToAnImage() {
        for name in ["a.png", "a.jpg", "a.jpeg", "a.gif", "a.webp",
                     "a.bmp", "a.tiff", "a.tif", "a.heic", "a.heif"] {
            #expect(kind(name) == .image, "\(name)")
        }
    }

    @Test func pdfResolvesToPDF() {
        #expect(kind("contract.pdf") == .pdf)
    }

    @Test func theExtensionIsMatchedWithoutCaringAboutCase() {
        #expect(kind("SHOT.PNG") == .image)
        #expect(kind("Contract.Pdf") == .pdf)
    }

    /// Source stays source. `svg` is the one worth stating: it is an image
    /// *format* and a text *file*, and a media tab has no way back to the
    /// source — so routing it here would take away the ability to edit it.
    @Test func whatStaysSource() {
        for name in ["logo.svg", "notes.md", "main.swift", "favicon.ico", "a.pdfx"] {
            #expect(kind(name) == nil, "\(name)")
        }
    }

    /// The extension is the *last* one, so a file that merely mentions a
    /// media suffix in the middle of its name is still text.
    @Test func onlyTheFinalExtensionCounts() {
        #expect(kind("notes.pdf.txt") == nil)
        #expect(kind("screenshot.png.bak") == nil)
    }

    @Test func aNameWithNoExtensionAtAllIsNotMedia() {
        #expect(kind("pdf") == nil)
        #expect(kind("Makefile") == nil)
    }

    /// A dotfile has no extension as far as `NSString` is concerned, which is
    /// surprising enough to pin: a file literally named `.pdf` is a config
    /// file, not a document.
    @Test func aDotfileIsNotMedia() {
        #expect(kind(".pdf") == nil)
        #expect(kind(".png") == nil)
    }
}

/// What the guard says about a media file, and — the part that matters — that
/// text files kept theirs.
struct MediaOpenGuardTests {
    @Test func mediaOpensAtASizeTheTextGuardRefuses() {
        let size = FileOpenGuard.maxBytes + 1
        #expect(FileOpenGuard.mediaVerdict(size: size) == .open)
        #expect(FileOpenGuard.verdict(size: size, prefix: Data()) == .tooLarge(bytes: size))
    }

    @Test func mediaIsStillRefusedPastItsOwnLimit() {
        let size = FileOpenGuard.maxMediaBytes + 1
        #expect(FileOpenGuard.mediaVerdict(size: size) == .tooLarge(bytes: size))
    }

    @Test func exactlyTheMediaLimitStillOpens() {
        #expect(FileOpenGuard.mediaVerdict(size: FileOpenGuard.maxMediaBytes) == .open)
    }

    /// The regression that matters: routing media away did not loosen the
    /// text guard, so a `.class` is still refused.
    @Test func aBinaryIsStillABinaryToTheTextGuard() {
        var data = Data("CAFEBABE".utf8)
        data.append(0)
        #expect(FileOpenGuard.verdict(size: data.count, prefix: data) == .binary)
    }
}

/// Opening media through `EditorCenter`: a tab, a viewer, and none of the
/// machinery that could damage the file.
@MainActor
struct EditorMediaOpenTests {
    /// Resolved through `realpath`, as the other file-touching suites do:
    /// temp directories sit behind the `/var` → `/private/var` symlink.
    private func workspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    @discardableResult
    private func write(_ directory: URL, _ name: String, _ bytes: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// A PDF with no NUL anywhere in its first 8KB — the shape that slips
    /// past the text guard's sniff. This is the file that used to open as an
    /// editable buffer.
    private func plausiblePDF() -> Data {
        var data = Data("%PDF-1.7\n".utf8)
        data.append(Data(repeating: UInt8(ascii: "A"), count: 9000))
        data.append(Data("\n%%EOF\n".utf8))
        return data
    }

    @Test func aPNGOpensWithNoTextDocumentBehindIt() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try write(base, "shot.png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        let center = EditorCenter()
        #expect(center.open(url))

        #expect(center.tabs.tabs.map(\.path) == [url.path])
        #expect(center.documents[url.path] == nil)
        #expect(center.media[url.path]?.kind == .image)
        #expect(center.selected?.media?.url == url)
        #expect(center.selectedDocument == nil)
    }

    /// The whole point of the change, stated as a file on disk: a PDF that
    /// the text guard would have let through is not an `EditorDocument`, so
    /// `saveAll` cannot rewrite it as UTF-8.
    @Test func savingEverythingLeavesAPDFByteForByteUntouched() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let original = plausiblePDF()
        let url = try write(base, "contract.pdf", original)

        /// The premise, first: this file really is one the text guard would
        /// have opened. Without this the test could pass for the wrong
        /// reason.
        #expect(FileOpenGuard.verdict(for: url) == .open)

        let center = EditorCenter()
        #expect(center.open(url))
        #expect(center.documents[url.path] == nil)

        center.saveAll()
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func aMediaTabIsNeverDirtyAndClosesWithoutAsking() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try write(base, "shot.png", Data([0x89, 0x50, 0x4E, 0x47]))

        let center = EditorCenter()
        #expect(center.open(url))
        #expect(!center.tabs.hasUnsavedChanges)

        center.requestClose(url.path)
        #expect(center.closeConfirmation == nil)
        #expect(center.media[url.path] == nil)
        #expect(center.tabs.tabs.isEmpty)
    }

    /// Opening the same media file again focuses its tab rather than building
    /// a second document — the already-open check keys on the media map, and
    /// reading the wrong one would re-run the size check on every click.
    @Test func openingTheSameFileTwiceKeepsOneTab() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try write(base, "shot.png", Data([0x89, 0x50]))

        let center = EditorCenter()
        #expect(center.open(url))
        #expect(center.open(url))
        #expect(center.tabs.tabs.count == 1)
    }

    /// Clicking an image in the Git panel passes `.diff`, which means nothing
    /// here. It has to land on the viewer rather than being stored.
    @Test func aPresentationRequestIsIgnoredForMedia() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try write(base, "shot.png", Data([0x89, 0x50]))

        let center = EditorCenter()
        #expect(center.open(url, showing: .diff, reviewBase: "main"))
        #expect(center.selected?.media != nil)
    }

    @Test func noLanguageServerIsToldAboutAMediaFile() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try write(base, "shot.png", Data([0x89, 0x50]))

        let center = EditorCenter()
        #expect(center.open(url))

        /// Asserts that `EditorCenter` does not announce it. That no view is
        /// built for it either comes from the type, not from here.
        #expect(!LSPCenter.shared.isOpen(path: url.path))
    }

    // MARK: Following the file around

    @Test func renamingTheFolderMovesTheMediaTab() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let assets = base.appendingPathComponent("assets", isDirectory: true)
        let url = try write(assets, "shot.png", Data([0x89, 0x50]))

        let center = EditorCenter()
        #expect(center.open(url))

        let moved = base.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.moveItem(at: assets, to: moved)
        center.repath(from: assets.path, to: moved.path)

        let newPath = moved.appendingPathComponent("shot.png").path
        #expect(center.media[url.path] == nil)
        #expect(center.media[newPath]?.kind == .image)
        #expect(center.tabs.tabs.map(\.path) == [newPath])
    }

    @Test func deletingTheFolderClosesTheMediaTab() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let assets = base.appendingPathComponent("assets", isDirectory: true)
        let url = try write(assets, "shot.png", Data([0x89, 0x50]))

        let center = EditorCenter()
        #expect(center.open(url))

        try FileManager.default.removeItem(at: assets)
        center.didDelete(path: assets.path)

        #expect(center.media.isEmpty)
        #expect(center.tabs.tabs.isEmpty)
    }

    @Test func closingEverythingClosesMediaToo() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let image = try write(base, "shot.png", Data([0x89, 0x50]))
        let source = try write(base, "a.ts", Data("const a = 1\n".utf8))

        let center = EditorCenter()
        #expect(center.open(image))
        #expect(center.open(source))

        center.closeAll()
        #expect(center.media.isEmpty)
        #expect(center.documents.isEmpty)
        #expect(center.tabs.tabs.isEmpty)
    }

    /// The frameworks can read the fixtures these tests write — really a
    /// fixture test, and the only thing worth asserting about the viewers
    /// without a window.
    @Test func theFixturesAreReadableByTheViewersOwnLoaders() throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }

        let pdf = try write(base, "contract.pdf", plausiblePDF())
        /// A deliberately malformed PDF: the viewer's failure message is
        /// reachable, which is why it exists.
        #expect(PDFDocument(url: pdf) == nil)

        let notAnImage = try write(base, "shot.png", Data("not a png".utf8))
        #expect(NSImage(contentsOf: notAnImage) == nil)
    }
}

/// The presentation model was left alone, and these are the sentences that
/// stay true because of it.
///
/// The alternative design put a `.media` case in `EditorPresentation`, which
/// would have cost `nearest(to:)` its guarantee — "never nil, because
/// `.source` is always in the list" — for every document in the app, to serve
/// one that is not a document at all.
struct MediaLeftThePresentationModelAloneTests {
    @Test func thereAreStillFourPresentations() {
        #expect(EditorPresentation.allCases.count == 4)
    }

    @Test func sourceIsStillAlwaysAvailable() {
        for name in ["a.png", "contract.pdf", "notes.md", "main.swift"] {
            let options = EditorPresentationOptions.resolve(fileName: name, hasChanges: false)
            #expect(options.available.first == .source, "\(name)")
        }
    }
}
