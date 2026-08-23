import Foundation
import Testing
@testable import Ghostty

/// Pins the moment the fork's configuration reaches disk.
///
/// The bug these regress: the store that seeds `sidebar = true` and appends
/// the `config-file` include is `@MainActor` and only materialized in
/// `applicationDidFinishLaunching`, while the core loads the configuration
/// back in `AppDelegate.init`. On a machine where the include was not already
/// there — a clean install — the whole launch ran on the core's defaults, and
/// `sidebar` defaults to false: bare windows with macOS's native tab bar,
/// until a later launch read what that one had written.
///
/// So what is tested is not that the values are right but that they are on
/// disk by the time `bootstrap` answers, which is before anything reads them.
@Suite
struct GuiConfigBootstrapTests {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func contents(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func bootstrapLeavesTheIncludeInTheMainConfig() throws {
        let dir = try makeDirectory()

        let mainPath = GuiConfigStore.bootstrap(in: dir)

        #expect(mainPath == dir.appendingPathComponent("config").path)
        #expect(contents(of: URL(fileURLWithPath: mainPath)).contains("config-file = gui-settings"))
    }

    @Test func bootstrapSeedsTheForkDefaults() throws {
        let dir = try makeDirectory()

        _ = GuiConfigStore.bootstrap(in: dir)

        let gui = contents(of: dir.appendingPathComponent("gui-settings"))
        #expect(gui.contains("sidebar = true"))
        #expect(gui.contains("window-save-state = always"))
    }

    /// A second launch must not append the include again, nor overwrite a
    /// setting the reader changed.
    @Test func bootstrapIsIdempotent() throws {
        let dir = try makeDirectory()

        _ = GuiConfigStore.bootstrap(in: dir)
        try "# managed\n\nsidebar = false\nwindow-save-state = never\n"
            .write(to: dir.appendingPathComponent("gui-settings"), atomically: true, encoding: .utf8)
        _ = GuiConfigStore.bootstrap(in: dir)

        let main = contents(of: dir.appendingPathComponent("config"))
        let includes = main.split(separator: "\n").filter { $0.contains("config-file") }
        #expect(includes.count == 1)

        let gui = contents(of: dir.appendingPathComponent("gui-settings"))
        #expect(gui.contains("sidebar = false"))
        #expect(gui.contains("window-save-state = never"))
    }

    /// The include is restored on a launch where the reader has rewritten
    /// their main config without it — otherwise every GUI setting silently
    /// stops applying and only a settings-window save brings them back.
    @Test func bootstrapPutsTheIncludeBackWhenItIsGone() throws {
        let dir = try makeDirectory()
        _ = GuiConfigStore.bootstrap(in: dir)
        try "font-size = 14\n"
            .write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        _ = GuiConfigStore.bootstrap(in: dir)

        let main = contents(of: dir.appendingPathComponent("config"))
        #expect(main.contains("font-size = 14"))
        #expect(main.contains("config-file = gui-settings"))
    }

    // MARK: - The defaults themselves

    @Test func forkDefaultsFillInWhatTheReaderHasNotSet() {
        var values: [String: String] = [:]

        #expect(GuiConfigStore.applyForkDefaults(to: &values))
        #expect(values["sidebar"] == "true")
        #expect(values["window-save-state"] == "always")
    }

    @Test func forkDefaultsLeaveTheReadersChoiceAlone() {
        var values = [
            "sidebar": "false",
            "window-save-state": "never",
            "background-blur": "0",
            "background-opacity": "1.0",
        ]

        #expect(!GuiConfigStore.applyForkDefaults(to: &values))
        #expect(values["sidebar"] == "false")
        #expect(values["window-save-state"] == "never")
        #expect(values["background-blur"] == "0")
        #expect(values["background-opacity"] == "1.0")
    }

    // MARK: Factory theme

    /// A first launch ships Phantom's own look: the theme file exists on
    /// disk where the Appearance pane can list and edit it, `theme` points
    /// at it, and glass is on at the shipped intensity.
    @Test func aVirginDirectoryGetsTheFactoryLook() throws {
        let dir = try makeDirectory()
        _ = GuiConfigStore.bootstrap(in: dir)

        let gui = contents(of: dir.appendingPathComponent(GuiConfigStore.fileName))
        #expect(gui.contains("background-blur = 80"))
        #expect(gui.contains("background-opacity = 0.80"))
        #expect(gui.contains("theme = "))
        #expect(gui.contains(GuiConfigStore.factoryThemeName))

        let theme = dir.appendingPathComponent("themes")
            .appendingPathComponent(GuiConfigStore.factoryThemeName)
        #expect(FileManager.default.fileExists(atPath: theme.path))
        #expect(contents(of: theme).contains("background = #060608"))
    }

    /// A reader's own choice is never overwritten — a `theme` already in the
    /// file means the factory theme is not materialized and not applied.
    @Test func aChosenThemeIsNeverReplaced() throws {
        let dir = try makeDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "theme = /somewhere/else\n".write(
            to: dir.appendingPathComponent(GuiConfigStore.fileName),
            atomically: true, encoding: .utf8)

        _ = GuiConfigStore.bootstrap(in: dir)

        let gui = contents(of: dir.appendingPathComponent(GuiConfigStore.fileName))
        #expect(gui.contains("theme = /somewhere/else"))
        #expect(!gui.contains(GuiConfigStore.factoryThemeName))
    }

    /// Blur and opacity the reader has touched stay theirs even when the
    /// theme key is the factory's to set.
    @Test func touchedGlassValuesSurviveTheFactoryDefaults() throws {
        let dir = try makeDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "background-blur = 20\nbackground-opacity = 1.0\n".write(
            to: dir.appendingPathComponent(GuiConfigStore.fileName),
            atomically: true, encoding: .utf8)

        _ = GuiConfigStore.bootstrap(in: dir)

        let gui = contents(of: dir.appendingPathComponent(GuiConfigStore.fileName))
        #expect(gui.contains("background-blur = 20"))
        #expect(gui.contains("background-opacity = 1.0"))
    }
}
