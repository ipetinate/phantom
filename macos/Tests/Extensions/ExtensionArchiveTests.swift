import Foundation
@testable import Ghostty
import Testing

struct ExtensionArchiveTests {
    @Test(arguments: [
        "extension.json", "icons/lua.svg", "icons/", "a/b/c.txt", "..hidden", "dots..inside", "./extension.json",
        "name with spaces.txt", "trailing/", "unicode-é.svg",
    ])
    func acceptsRelativePathsThatStayInside(_ path: String) {
        #expect(ExtensionArchive.rejection(forEntry: path) == nil)
    }

    @Test(arguments: ["/etc/passwd", "/", "//double", "/extension.json"])
    func refusesAbsolutePaths(_ path: String) {
        #expect(ExtensionArchive.rejection(forEntry: path) == .absolute(path))
    }

    @Test(arguments: ["../escape", "a/../../b", "..", "icons/..", "a/.."])
    func refusesParentReferences(_ path: String) {
        #expect(ExtensionArchive.rejection(forEntry: path) == .parentReference(path))
    }

    @Test func refusesAnEmptyEntry() {
        #expect(ExtensionArchive.rejection(forEntry: "") == .empty)
    }

    @Test(arguments: ["..\\escape", "a\\b", "new\nline", "tab\there", "bidi\u{202E}.svg", "nul\u{0}"])
    func refusesPathsThisAppWillNotWrite(_ path: String) {
        #expect(ExtensionArchive.rejection(forEntry: path) == .unsafeCharacter(path))
    }

    @Test func theFirstOffenderInAListingIsReported() {
        let entries = ["extension.json", "icons/lua.svg", "../escape", "/abs"]
        #expect(ExtensionArchive.firstRejection(in: entries) == .parentReference("../escape"))
        #expect(ExtensionArchive.firstRejection(in: ["extension.json", "icons/lua.svg"]) == nil)
        #expect(ExtensionArchive.firstRejection(in: []) == nil)
    }

    @Test func theManifestHasToSitAtTheRoot() {
        #expect(ExtensionArchive.hasManifestAtRoot(["extension.json", "icons/lua.svg"]))
        #expect(ExtensionArchive.hasManifestAtRoot(["./extension.json"]))
        #expect(!ExtensionArchive.hasManifestAtRoot(["lua/extension.json", "lua/icons/lua.svg"]))
        #expect(!ExtensionArchive.hasManifestAtRoot(["Extension.json"]))
        #expect(!ExtensionArchive.hasManifestAtRoot([]))
    }

    @Test func aListingSplitsIntoEntriesWithoutInventingAnEmptyLast() {
        #expect(ExtensionArchive.entries(fromListing: "extension.json\nicons/lua.svg\n") == ["extension.json", "icons/lua.svg"])
        #expect(ExtensionArchive.entries(fromListing: "extension.json") == ["extension.json"])
        #expect(ExtensionArchive.entries(fromListing: "") == [])
        #expect(ExtensionArchive.entries(fromListing: "a\n\nb\n") == ["a", "", "b"])
    }

    @Test func anEmptyLineInsideAListingIsAnEmptyEntry() {
        let entries = ExtensionArchive.entries(fromListing: "extension.json\n\nicons/lua.svg\n")
        #expect(ExtensionArchive.firstRejection(in: entries) == .empty)
    }

    @Test func containmentNeedsAStrictDescendant() {
        let root = "/Users/me/.config/phantom/extensions"
        #expect(ExtensionArchive.isContained(path: root + "/ipetinate.lua", inDirectory: root))
        #expect(ExtensionArchive.isContained(path: root + "/a/b", inDirectory: root + "/"))
        #expect(!ExtensionArchive.isContained(path: root, inDirectory: root))
        #expect(!ExtensionArchive.isContained(path: root + "/", inDirectory: root))
        #expect(!ExtensionArchive.isContained(path: root + "-other/x", inDirectory: root))
        #expect(!ExtensionArchive.isContained(path: "/Users/me/.config/phantom", inDirectory: root))
        #expect(!ExtensionArchive.isContained(path: "/etc/passwd", inDirectory: root))
    }

    @Test func aShownPathIsEscapedAndBounded() {
        #expect(ExtensionArchive.shown("bidi\u{202E}.svg") == "bidi\\u{202E}.svg")
        let long = String(repeating: "x", count: 200)
        #expect(ExtensionArchive.shown(long).count == 80)
        #expect(ExtensionArchive.shown(long).hasSuffix("..."))
    }
}
