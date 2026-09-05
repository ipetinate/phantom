import Foundation
@testable import Ghostty
import Testing

struct ExtensionDocumentTests {
    private func entry(id: String = "ipetinate.lua", name: String = "Lua", card: ExtensionCard? = nil) -> ExtensionIndex.Entry {
        ExtensionIndex.Entry(
            id: id,
            name: name,
            version: "1.0.0",
            publisher: "ipetinate",
            summary: "",
            homepage: nil,
            minimumPhantomVersion: nil,
            contributes: [],
            languages: [],
            downloadURL: URL(string: "https://example.com/\(id).zip")!,
            sha256: String(repeating: "a", count: 64),
            bytes: 1,
            card: card)
    }

    @Test func aDocumentIsKeyedByItsExtensionId() {
        let document = ExtensionDocument(extensionID: "ipetinate.lua", title: "Lua")
        #expect(document.path == "phantom-extension://ipetinate.lua")
        #expect(document.id == document.path)
        #expect(ExtensionDocument.extensionID(fromPath: document.path) == "ipetinate.lua")
    }

    @Test func onlyAnExtensionPathReadsBackToAnId() {
        for path in ["/Users/reader/lua.lua", "phantom-extension://", "phantom-extension://../x",
                     "phantom-extension://a/b", "https://example.com", "phantom-extension:ipetinate.lua"] {
            #expect(ExtensionDocument.extensionID(fromPath: path) == nil, "\(path)")
        }
    }

    @Test func theTitleComesFromTheCardWhenThereIsOne() throws {
        #expect(ExtensionDocument(entry: entry()).title == "Lua")

        let card = try #require(ExtensionCard.parse(ExtensionCardTests.card(["title": "Lua Language"])))
        #expect(ExtensionDocument(entry: entry(card: card)).title == "Lua Language")

        let installed = InstalledExtension(
            id: "acme.zig", name: "Zig", version: "0.1.0", root: URL(fileURLWithPath: "/tmp/zig"))
        #expect(ExtensionDocument(installed: installed).title == "Zig")
        #expect(ExtensionDocument(installed: installed).extensionID == "acme.zig")
    }

    @Test func theTabWearsTheTitleAndThePuzzlePiece() {
        let tab = ExtensionDocument(extensionID: "ipetinate.lua", title: "Lua").tab
        #expect(tab.path == "phantom-extension://ipetinate.lua")
        #expect(tab.name == "Lua")
        #expect(tab.symbol == ExtensionDocument.symbol)
        #expect(!tab.isDirty)
        #expect(!tab.isPinned)
    }

    @Test func aPlainTabStillNamesItselfAfterItsFile() {
        let tab = EditorTab(path: "/Users/reader/src/main.swift")
        #expect(tab.name == "main.swift")
        #expect(tab.symbol == nil)
    }

    @Test func aRenamedTabKeepsItsTitleAndSymbol() {
        var tabs = EditorTabSet()
        tabs.open(EditorTab(path: "/a/one", title: "One", symbol: "star"))
        tabs.repath(from: "/a/one", to: "/b/one")
        let tab = tabs.tab(for: "/b/one")
        #expect(tab?.title == "One")
        #expect(tab?.symbol == "star")
    }

    @Test func openingATabAgainRetitlesRatherThanDuplicates() {
        var tabs = EditorTabSet()
        tabs.open(EditorTab(path: "phantom-extension://ipetinate.lua", title: "Lua", symbol: "puzzlepiece.extension"))
        tabs.open("/Users/reader/notes.md")
        tabs.open(EditorTab(path: "phantom-extension://ipetinate.lua", title: "Lua Language", symbol: "puzzlepiece.extension"))

        #expect(tabs.tabs.map(\.path) == ["phantom-extension://ipetinate.lua", "/Users/reader/notes.md"])
        #expect(tabs.tabs.first?.name == "Lua Language")
        #expect(tabs.selectedPath == "phantom-extension://ipetinate.lua")

        tabs.open("/Users/reader/notes.md")
        #expect(tabs.tab(for: "/Users/reader/notes.md")?.title == nil)
    }
}

@MainActor
struct ExtensionDocumentCenterTests {
    private let lua = ExtensionDocument(extensionID: "ipetinate.lua", title: "Lua")
    private let zig = ExtensionDocument(extensionID: "acme.zig", title: "Zig")

    @Test func openingAnExtensionMakesATabAndSelectsIt() {
        let center = EditorCenter()

        center.openExtension(lua)

        #expect(center.tabs.selectedPath == lua.path)
        #expect(center.tabs.tabs.map(\.name) == ["Lua"])
        #expect(center.extensions[lua.path] == lua)
        #expect(center.selected?.extensionDocument == lua)
        #expect(center.selected?.text == nil)
        #expect(center.selected?.media == nil)
        #expect(center.showsEditor)
        #expect(center.isOpen(lua.path))
    }

    @Test func openingTheSameExtensionAgainFocusesTheExistingTab() {
        let center = EditorCenter()

        center.openExtension(lua)
        center.openExtension(zig)
        center.openExtension(ExtensionDocument(extensionID: "ipetinate.lua", title: "Lua Language"))

        #expect(center.tabs.tabs.map(\.path) == [lua.path, zig.path])
        #expect(center.tabs.selectedPath == lua.path)
        #expect(center.tabs.tabs.first?.name == "Lua Language")
        #expect(center.extensions[lua.path]?.title == "Lua Language")
    }

    @Test func closingTheTabForgetsTheDocument() {
        let center = EditorCenter()
        center.openExtension(lua)
        center.openExtension(zig)

        center.requestClose(zig.path)

        #expect(center.extensions[zig.path] == nil)
        #expect(center.tabs.tabs.map(\.path) == [lua.path])
        #expect(center.tabs.selectedPath == lua.path)

        center.close(lua.path)
        #expect(center.extensions.isEmpty)
        #expect(center.tabs.tabs.isEmpty)
        #expect(!center.showsEditor)
    }

    @Test func closeAllClearsExtensionsToo() {
        let center = EditorCenter()
        center.openExtension(lua)
        center.openExtension(zig)

        center.closeAll()

        #expect(center.extensions.isEmpty)
        #expect(center.tabs.tabs.isEmpty)
        #expect(center.selected == nil)
    }

    @Test func selectingTheTerminalAndComingBackKeepsTheDocument() {
        let center = EditorCenter()
        center.openExtension(lua)

        center.selectTerminal()
        #expect(!center.showsEditor)
        #expect(center.extensions[lua.path] == lua)

        center.select(lua.path)
        #expect(center.selected?.extensionDocument == lua)
    }
}
