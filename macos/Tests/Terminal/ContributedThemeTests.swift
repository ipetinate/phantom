import AppKit
import Foundation
@testable import Ghostty
import Testing

struct ContributedThemeTests {
    private static let colorTheme = """
    background = #1e1e2e
    foreground = #cdd6f4
    cursor-color = #f5e0dc
    palette = 0=#45475a
    palette = 4=#89b4fa

    """

    private func makeRoot(directory: String, themes: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-themes-" + UUID().uuidString)
            .appendingPathComponent(directory)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("themes"),
            withIntermediateDirectories: true
        )
        for file in themes {
            try Self.colorTheme.write(
                to: root.appendingPathComponent("themes/" + file),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }

    private func manifest(
        root: URL,
        id: String,
        name: String,
        scope: LanguageManifest.Scope = .user,
        themes: String
    ) -> LanguageManifest {
        let json = #"""
        {
          "schemaVersion": 1,
          "id": "\#(id)",
          "name": "\#(name)",
          "version": "1.0.0",
          "publisher": "acme",
          "contributes": { "themes": [\#(themes)] }
        }
        """#
        return LanguageManifest.parse(
            data: Data(json.utf8),
            url: root.appendingPathComponent(LanguageManifest.fileName),
            root: root,
            scope: scope
        )!
    }

    // MARK: The catalog

    @Test func contributedThemesAreAggregatedWithTheirExtensionsName() throws {
        let root = try makeRoot(directory: "acme.lua", themes: ["lua-dark", "lua-light"])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = LanguageCatalog.resolve(
            manifests: [manifest(root: root, id: "acme.lua", name: "Lua", themes: #"""
            { "name": "Lua Light", "path": "themes/lua-light", "appearance": "light" },
            { "name": "Lua Dark", "path": "themes/lua-dark", "appearance": "dark" }
            """#)],
            promotions: []
        )

        #expect(catalog.themes.map(\.theme.name) == ["Lua Dark", "Lua Light"])
        let dark = try #require(catalog.themes.first)
        #expect(dark.extensionName == "Lua")
        #expect(dark.listIdentity == "acme.lua")
        #expect(dark.id == "acme.lua#theme:Lua Dark")
        #expect(dark.theme.appearance == .dark)
        #expect(dark.theme.fileURL.lastPathComponent == "lua-dark")
        #expect(catalog.entries.first?.manifest.isUsable == true)
    }

    @Test func twoExtensionsContributingTheSameNameResolveLexicographically() throws {
        let zeta = try makeRoot(directory: "zeta.pack", themes: ["shared"])
        let alpha = try makeRoot(directory: "alpha.pack", themes: ["shared"])
        defer {
            try? FileManager.default.removeItem(at: zeta.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: alpha.deletingLastPathComponent())
        }
        let entry = #"{ "name": "Shared", "path": "themes/shared" }"#

        let catalog = LanguageCatalog.resolve(
            manifests: [
                manifest(root: zeta, id: "zeta.pack", name: "Zeta", themes: entry),
                manifest(root: alpha, id: "alpha.pack", name: "Alpha", themes: entry),
            ],
            promotions: []
        )

        #expect(catalog.themes.count == 1)
        #expect(catalog.themes.first?.listIdentity == "alpha.pack")
    }

    @Test func aUserExtensionsThemeOutranksABundledOnesOfTheSameName() throws {
        let bundled = try makeRoot(directory: "alpha.pack", themes: ["shared"])
        let user = try makeRoot(directory: "zeta.pack", themes: ["shared"])
        defer {
            try? FileManager.default.removeItem(at: bundled.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: user.deletingLastPathComponent())
        }
        let entry = #"{ "name": "Shared", "path": "themes/shared" }"#

        let catalog = LanguageCatalog.resolve(
            manifests: [
                manifest(root: bundled, id: "alpha.pack", name: "Alpha", scope: .bundled, themes: entry),
                manifest(root: user, id: "zeta.pack", name: "Zeta", scope: .user, themes: entry),
            ],
            promotions: []
        )
        #expect(catalog.themes.map(\.listIdentity) == ["zeta.pack"])
    }

    @Test func theEmptyCatalogHasNoThemes() {
        #expect(LanguageCatalog.empty.themes.isEmpty)
    }

    // MARK: The theme catalog's view of it

    @Test func aContributedThemeParsesUnderTheManifestsNameAndSource() throws {
        let root = try makeRoot(directory: "acme.lua", themes: ["lua-dark"])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let url = root.appendingPathComponent("themes/lua-dark")

        let theme = try #require(ThemeCatalog.parse(
            url: url,
            source: .contributed(extension: "Lua"),
            name: "Lua Dark"
        ))

        #expect(theme.name == "Lua Dark")
        #expect(theme.source == .contributed(extension: "Lua"))
        #expect(theme.url == url)
        #expect(theme.background == NSColor(hex: "#1e1e2e"))
        #expect(theme.palette[4] == NSColor(hex: "#89b4fa"))
        #expect(theme.id == "extension:Lua:Lua Dark")
    }

    @Test func aFileNameStaysTheNameWhenNoneIsGiven() throws {
        let root = try makeRoot(directory: "acme.lua", themes: ["lua-dark"])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let theme = ThemeCatalog.parse(url: root.appendingPathComponent("themes/lua-dark"), source: .user)
        #expect(theme?.name == "lua-dark")
        #expect(theme?.id == "user:lua-dark")
    }

    @Test func theThreeSourcesOfOneNameAreThreeIdentities() {
        let url = URL(fileURLWithPath: "/tmp/Dracula")
        let ids = Set([
            TerminalTheme(name: "Dracula", source: .builtin, url: url).id,
            TerminalTheme(name: "Dracula", source: .user, url: url).id,
            TerminalTheme(name: "Dracula", source: .contributed(extension: "Pack"), url: url).id,
        ])
        #expect(ids.count == 3)
    }

    @Test func contributedThemesSortBetweenTheUsersAndTheBundled() {
        #expect(TerminalTheme.Source.user.sortRank < TerminalTheme.Source.contributed(extension: "x").sortRank)
        #expect(TerminalTheme.Source.contributed(extension: "x").sortRank < TerminalTheme.Source.builtin.sortRank)
    }
}

@MainActor
struct ContributedThemeStoreTests {
    private func makeStore() throws -> (store: GuiConfigStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (GuiConfigStore(configDir: dir), dir)
    }

    @Test func aContributedThemeIsWrittenAsItsAbsolutePath() throws {
        let (store, dir) = try makeStore()
        let url = dir.appendingPathComponent("extensions/acme.lua/themes/lua-dark")
        let theme = TerminalTheme(name: "Lua Dark", source: .contributed(extension: "Lua"), url: url)

        store.setTheme(theme)

        #expect(store.string("theme") == url.path)
        #expect(store.currentThemeURL == url)
        #expect(store.isCurrentTheme(theme))
    }

    @Test func aContributedThemeIsCurrentByPathAndNotByName() throws {
        let (store, dir) = try makeStore()
        let url = dir.appendingPathComponent("extensions/acme.lua/themes/lua-dark")
        let contributed = TerminalTheme(name: "Lua Dark", source: .contributed(extension: "Lua"), url: url)
        let other = TerminalTheme(
            name: "Lua Dark",
            source: .contributed(extension: "Other"),
            url: dir.appendingPathComponent("extensions/other/themes/lua-dark")
        )

        store.setTheme(contributed)

        #expect(store.isCurrentTheme(contributed))
        #expect(!store.isCurrentTheme(other))
        #expect(!store.isCurrentTheme(TerminalTheme(name: "Lua Dark", source: .builtin, url: url)))
    }

    @Test func theExistingSourcesAreStillCurrentByName() throws {
        let (store, dir) = try makeStore()
        let userURL = dir.appendingPathComponent("themes/Mine")
        let user = TerminalTheme(name: "Mine", source: .user, url: userURL)
        let builtin = TerminalTheme(name: "Dracula", source: .builtin, url: URL(fileURLWithPath: "/bundle/Dracula"))

        store.setTheme(user)
        #expect(store.isCurrentTheme(user))
        #expect(!store.isCurrentTheme(builtin))

        store.setTheme(builtin)
        #expect(store.isCurrentTheme(builtin))
        #expect(!store.isCurrentTheme(user))
    }
}
