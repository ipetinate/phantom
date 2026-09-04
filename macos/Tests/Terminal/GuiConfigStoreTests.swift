import Foundation
@testable import Ghostty
import Testing

/// Exercises `GuiConfigStore` against a throwaway config directory rather
/// than the real one, using the `configDir:` seam its initializer already
/// exposes — no production code changed to make this testable.
@MainActor
struct GuiConfigStoreTests {
    private func makeStore() throws -> (store: GuiConfigStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (GuiConfigStore(configDir: dir), dir)
    }

    // MARK: - currentThemeName

    /// See `aFreshStoreStartsOnTheFactoryTheme` — an empty `theme` key is
    /// filled by the factory at init, so the name is never nil on a fresh
    /// store.
    @Test func aFreshStoreNamesTheFactoryTheme() throws {
        let (store, _) = try makeStore()
        #expect(store.currentThemeName == GuiConfigStore.factoryThemeName)
    }

    @Test func currentThemeNameReturnsABuiltinNameAsIs() throws {
        let (store, _) = try makeStore()
        store.set("theme", "Dracula Darker")
        #expect(store.currentThemeName == "Dracula Darker")
    }

    /// The bug this regresses: a custom theme is stored as an absolute
    /// path, and comparing that path against a catalog entry's bare name
    /// (`theme.name == currentTheme`) never matched, so the theme in use
    /// never showed as selected. Only the last path component should be
    /// compared.
    @Test func currentThemeNameStripsTheDirectoryFromACustomThemePath() throws {
        let (store, dir) = try makeStore()
        let themePath = dir.appendingPathComponent("themes/My Custom Theme").path
        store.set("theme", themePath)
        #expect(store.currentThemeName == "My Custom Theme")
    }

    // MARK: - currentThemeURL

    /// "Unset" stopped being a reachable resting state: a store whose
    /// `theme` key is empty materializes the factory theme at init and
    /// points at it, so a fresh store starts on "Dracula by Phantom" rather
    /// than on nothing.
    @Test func aFreshStoreStartsOnTheFactoryTheme() throws {
        let (store, _) = try makeStore()
        let url = try #require(store.currentThemeURL)
        #expect(url.lastPathComponent == GuiConfigStore.factoryThemeName)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The actual bug: a custom theme's `theme` value is an absolute path.
    /// Resolving it must load that exact file rather than searching
    /// Phantom's or the bundle's `themes` directory for a name — that
    /// search is what failed and showed a "theme not found" dialog for a
    /// theme that existed right where it was written.
    @Test func currentThemeURLResolvesAnAbsolutePathDirectly() throws {
        let (store, dir) = try makeStore()
        let themeURL = dir.appendingPathComponent("themes/Dracula Darker")
        try FileManager.default.createDirectory(
            at: themeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "background = #000000\n".write(to: themeURL, atomically: true, encoding: .utf8)

        store.set("theme", themeURL.path)
        #expect(store.currentThemeURL == themeURL)
    }

    @Test func currentThemeURLFindsABareNameInTheUserThemesDirectory() throws {
        let (store, dir) = try makeStore()
        let themeURL = dir.appendingPathComponent("themes/My Theme")
        try FileManager.default.createDirectory(
            at: themeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "background = #111111\n".write(to: themeURL, atomically: true, encoding: .utf8)

        store.set("theme", "My Theme")
        #expect(store.currentThemeURL == themeURL)
    }

    /// A bare name absent from the user directory falls through to the
    /// bundle's built-in themes — still resolved from a name, never from a
    /// path, so this must not accidentally match `themesDirURL`.
    @Test func currentThemeURLFallsBackToTheBuiltinDirectoryForAnUnknownName() throws {
        let (store, dir) = try makeStore()
        store.set("theme", "Some Builtin Theme")

        let resolved = try #require(store.currentThemeURL)
        #expect(resolved != dir.appendingPathComponent("themes/Some Builtin Theme"))
        #expect(resolved.lastPathComponent == "Some Builtin Theme")
    }

    // MARK: - setTheme

    @Test func setThemeStoresAnAbsolutePathForAUserTheme() throws {
        let (store, dir) = try makeStore()
        let themeURL = dir.appendingPathComponent("themes/Mine")
        let theme = TerminalTheme(name: "Mine", source: .user, url: themeURL)

        store.setTheme(theme)
        #expect(store.string("theme") == themeURL.path)
    }

    @Test func setThemeStoresABareNameForABuiltinTheme() throws {
        let (store, _) = try makeStore()
        let theme = TerminalTheme(
            name: "Dracula",
            source: .builtin,
            url: URL(fileURLWithPath: "/some/bundle/path/Dracula")
        )

        store.setTheme(theme)
        #expect(store.string("theme") == "Dracula")
    }

    // MARK: - One config directory per build

    /// The release build keeps the directory it has always had. Anything else
    /// here would be a migration on the app the reader actually uses, for a
    /// fault that is not theirs.
    @Test func theReleaseBuildHasNoSuffix() {
        #expect(GuiConfigStore.buildSuffix(forBundleID: "com.ipetinate.phantom") == nil)
    }

    /// The fault this exists for: a debug build wrote `gui-settings` and
    /// `config` into the release build's directory, which the running release
    /// app watches — so trying something out in one app changed the other one
    /// under the reader.
    @Test func aDebugBuildIsToldApartByItsBundleID() {
        #expect(GuiConfigStore.buildSuffix(forBundleID: "com.ipetinate.phantom.debug") == "debug")
    }

    /// The same rule `MCPServerCommand` uses for the socket and the agent
    /// entry, so a third build gets a third directory rather than sharing one
    /// with whichever it resembles.
    @Test func anyOtherVariantGetsItsOwnDirectory() {
        #expect(GuiConfigStore.buildSuffix(forBundleID: "com.ipetinate.phantom.nightly") == "nightly")
        #expect(GuiConfigStore.buildSuffix(forBundleID: "com.ipetinate.Phantom") == nil)
        #expect(GuiConfigStore.buildSuffix(forBundleID: "") == nil)
    }

    // MARK: What a second build may read, and where it writes

    /// The release build has one directory and reads it. Nothing to fall back
    /// to, and no duplicate of itself in the list.
    @Test func theReleaseBuildReadsOneThemeDirectory() {
        let store = GuiConfigStore(configDir: GuiConfigStore.sharedConfigDir())
        #expect(store.themeSearchDirs == [store.themesDirURL])
    }

    /// A second build reads its own first and the reader's after. This is the
    /// defect it was written for: only the config files are copied when a
    /// build makes its own directory, so its `themes` starts empty and the
    /// reader's own theme vanished from Appearance along with its section.
    @Test func asecondBuildFallsBackToTheReadersThemes() {
        let own = GuiConfigStore.sharedConfigDir()
            .deletingLastPathComponent()
            .appendingPathComponent("phantom-debug", isDirectory: true)
        let store = GuiConfigStore(configDir: own)

        let dirs = store.themeSearchDirs
        #expect(dirs.count == 2)
        #expect(dirs.first == store.themesDirURL)
        #expect(dirs.last == GuiConfigStore.sharedConfigDir()
            .appendingPathComponent("themes", isDirectory: true))
    }

    /// And it still writes into its own. Reading the reader's configuration is
    /// what makes a second build usable; writing to it is the thing the
    /// separate directory exists to prevent.
    @Test func asecondBuildStillWritesIntoItsOwn() {
        let own = GuiConfigStore.sharedConfigDir()
            .deletingLastPathComponent()
            .appendingPathComponent("phantom-debug", isDirectory: true)
        let store = GuiConfigStore(configDir: own)

        #expect(store.themesDirURL.path.hasPrefix(own.path))
        #expect(store.themesDirURL != GuiConfigStore.sharedConfigDir()
            .appendingPathComponent("themes", isDirectory: true))
    }
}
