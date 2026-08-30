import Foundation
import Combine

/// Owns the GUI-managed slice of the Ghostty configuration.
///
/// Settings edited through the settings window are written to a dedicated
/// file (`gui-settings`) inside the user's config directory, which is
/// included from the main config via a `config-file` directive. The main
/// config file is never rewritten beyond appending that single include,
/// so hand-edited configuration always survives.
@MainActor
final class GuiConfigStore: ObservableObject {
    static let shared = GuiConfigStore()

    static let fileName = "gui-settings"

    @Published private(set) var values: [String: String] = [:]

    private let configDir: URL

    var guiFileURL: URL { configDir.appendingPathComponent(Self.fileName) }
    var mainConfigURL: URL { configDir.appendingPathComponent("config") }
    var themesDirURL: URL { configDir.appendingPathComponent("themes", isDirectory: true) }

    /// Where user-installed file-icon themes live. Any SVG-based VS Code
    /// icon theme works: copy the extension's folder in, one directory per
    /// theme, each containing its own `icon-theme.json`.
    var iconThemesDirURL: URL { configDir.appendingPathComponent("icon-themes", isDirectory: true) }

    /// Where user-installed language extensions live: one directory per
    /// extension, each holding an `extension.json`. See `LanguageManifest`.
    ///
    /// Note what is *not* kept here — the record of which extensions the
    /// user has trusted, which lives in `UserDefaults`. This directory is
    /// writable by whatever put a manifest in it, so a trust decision stored
    /// alongside would be one the manifest's author could grant itself.
    var extensionsDirURL: URL { configDir.appendingPathComponent("extensions", isDirectory: true) }

    init(configDir: URL? = nil) {
        self.configDir = configDir ?? Self.defaultConfigDir()
        load()
        var changed = Self.applyForkDefaults(to: &values)
        changed = Self.applyFactoryTheme(to: &values, in: self.configDir) || changed
        if changed { save() }
    }

    // MARK: Bootstrap

    /// Puts the fork's configuration on disk — the GUI file, its defaults and
    /// the `config-file` include — and answers the path the core should read.
    ///
    /// This is about ordering, not tidiness. `AppDelegate.init` constructs
    /// `Ghostty.App`, which loads the configuration on the spot, while
    /// `shared` is `@MainActor` and does not materialize until
    /// `applicationDidFinishLaunching` — after that load, and after window
    /// restoration. So on any launch where the include was not already in the
    /// main config (a new machine, a fresh config directory, a config the
    /// reader rewrote) the *entire* launch ran on the core's own defaults,
    /// where `sidebar` is false: windows came up bare, with macOS's native tab
    /// bar instead of the sidebar, and the app looked broken until a later
    /// launch read the file this one had just written. Seeding here closes
    /// that window — the include exists before anything reads the config, so
    /// nothing has to reload it afterwards.
    ///
    /// Spelled over files rather than over `shared`, and `nonisolated`,
    /// because `AppDelegate.init` is not on the main actor. That is the same
    /// constraint `mainConfigPath` was written for; this does the rest of the
    /// job that one stopped short of.
    nonisolated static func bootstrap() -> String {
        bootstrap(in: defaultConfigDir())
    }

    /// `bootstrap`, against a given directory, so the ordering it exists to
    /// guarantee can be exercised without the real config directory.
    nonisolated static func bootstrap(in dir: URL) -> String {
        let mainPath = mainConfigPath(in: dir)

        var values = readGuiValues(in: dir)
        var changed = applyForkDefaults(to: &values)
        changed = applyFactoryTheme(to: &values, in: dir) || changed
        if changed { writeGuiValues(values, in: dir) }

        /// Every launch, not only the one that wrote the file: the include is
        /// a single line in a file the reader owns and may have rewritten, and
        /// without it every setting in `gui-settings` is invisible to the core.
        ensureIncluded(in: dir)

        return mainPath
    }

    /// The fork's defaults, applied only where the reader has not set the key.
    /// Answers whether anything changed.
    ///
    /// A static over a dictionary because two callers need it at two very
    /// different moments — `bootstrap`, before the app exists, and `init`,
    /// once it does — and a default that only one of them applied is exactly
    /// the failure this pair exists to prevent.
    nonisolated static func applyForkDefaults(to values: inout [String: String]) -> Bool {
        // Fork defaults, applied only when the user hasn't set the key:
        // the sidebar is the point of this fork, and session restore is
        // expected behavior with it.
        var needsSave = false
        // The appearance model is theme -> effect + intensity + opacity;
        // a background color override no longer exists.
        if values["background"] != nil {
            values.removeValue(forKey: "background")
            needsSave = true
        }
        if values["sidebar"] == nil {
            values["sidebar"] = "true"
            needsSave = true
        }
        if values["window-save-state"] == nil {
            values["window-save-state"] = "always"
            needsSave = true
        }
        /// The factory look: Phantom's own take on Dracula, on glass. Only
        /// where the reader has never chosen — a `theme` of their own, or a
        /// blur or opacity they have touched, is theirs and stays.
        if values["background-blur"] == nil {
            values["background-blur"] = "80"
            needsSave = true
        }
        if values["background-opacity"] == nil {
            values["background-opacity"] = "0.80"
            needsSave = true
        }
        return needsSave
    }

    /// The theme Phantom ships applied, written into the user's own themes
    /// directory so the Appearance pane lists and edits it like any custom
    /// theme — deleting or renaming it is the reader's right, so it is
    /// materialized only while the `theme` key is unset (a first launch, or
    /// a config the reader reset), never re-imposed over a choice.
    nonisolated static let factoryThemeName = "Dracula by Phantom"

    nonisolated static let factoryTheme = """
    background = #060608
    foreground = #F8F8F2
    cursor-color = #F8F8F2
    selection-background = #44475A
    palette = 0=#21222C
    palette = 1=#FF5555
    palette = 2=#50FA7B
    palette = 3=#F1FA8C
    palette = 4=#BD93F9
    palette = 5=#FF79C6
    palette = 6=#8BE9FD
    palette = 7=#F8F8F2
    palette = 8=#6272A4
    palette = 9=#FF6E6E
    palette = 10=#69FF94
    palette = 11=#FFFFA5
    palette = 12=#D6ACFF
    palette = 13=#FF92DF
    palette = 14=#A4FFFF
    palette = 15=#FFFFFF

    """

    /// Materializes the factory theme and points `theme` at it. File work,
    /// nonisolated, bootstrap-time — same constraints as everything else in
    /// the bootstrap: it must run before the core loads the config.
    nonisolated static func applyFactoryTheme(
        to values: inout [String: String],
        in dir: URL
    ) -> Bool {
        guard values["theme"] == nil else { return false }

        let themes = dir.appendingPathComponent("themes", isDirectory: true)
        let file = themes.appendingPathComponent(factoryThemeName)
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(
                at: themes, withIntermediateDirectories: true)
            guard (try? factoryTheme.write(to: file, atomically: true, encoding: .utf8)) != nil
            else { return false }
        }
        values["theme"] = file.path
        return true
    }

    /// The main config file the Ghostty core should load, resolved without
    /// touching the shared instance so it can be read before the app (and
    /// thus the main actor) is up — see `bootstrap`.
    ///
    /// Creates the file when it is missing: the core logs an error and falls
    /// back to built-in defaults for a path that doesn't exist, which on a
    /// first launch would silently discard the user's configuration until
    /// something happened to write it.
    nonisolated private static func mainConfigPath(in dir: URL) -> String {
        let url = dir.appendingPathComponent("config")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
        return url.path
    }

    /// Where **this build** reads and writes its configuration.
    ///
    /// The release build's answer is the one it has always given, and nothing
    /// about it changes. Every other build — the debug one — gets a directory
    /// of its own beside it, seeded once with a copy of the two files the
    /// settings window writes, and diverges from there.
    ///
    /// Sharing was not a harmless duplicate. `gui-settings` and `config` are
    /// watched by the running app: a debug build opened to try something out
    /// wrote the release build's configuration underneath it, which the reader
    /// then saw take effect in the app they were actually working in.
    /// `PhantomStateFile` fixed the same fault for state a while ago, and left
    /// this one — the state files are keyed by bundle id; this directory was
    /// spelled `phantom` for everybody.
    ///
    /// Only the two files are copied. Themes, extensions and icon themes stay
    /// where they are and are not duplicated: a theme is referenced from
    /// `gui-settings` by absolute path, so the copy keeps pointing at the one
    /// the reader installed, and a debug build with no icon themes of its own
    /// falls back to the ones in the bundle. Copying a directory of somebody's
    /// icon sets on launch to spare a debug build that fallback is the wrong
    /// trade.
    nonisolated private static func defaultConfigDir() -> URL {
        let shared = sharedConfigDir()
        guard let suffix = buildSuffix else { return shared }

        let own = shared
            .deletingLastPathComponent()
            .appendingPathComponent("\(shared.lastPathComponent)-\(suffix)", isDirectory: true)

        /// Copy once, never over anything, never a move — the reader's own
        /// configuration has to survive whatever this build does next.
        for name in [fileName, "config"] {
            PhantomStateFile.migrate(
                from: shared.appendingPathComponent(name),
                to: own.appendingPathComponent(name))
        }
        return own
    }

    /// What marks this build's directory apart, or nil for the release build.
    ///
    /// The suffix comes off the bundle id, which is the same rule
    /// `MCPServerCommand.name(forBundleID:)` uses to name the socket and the
    /// agent entry — `com.ipetinate.phantom` is the release build and answers
    /// nil, `com.ipetinate.phantom.debug` answers `debug`. Stated again rather
    /// than borrowed because that one is `@MainActor` and this runs during
    /// bootstrap, before there is a main actor to be on.
    nonisolated static func buildSuffix(forBundleID id: String) -> String? {
        guard let variant = id.split(separator: ".").last,
              !variant.isEmpty,
              variant.lowercased() != "phantom"
        else { return nil }
        return variant.lowercased()
    }

    nonisolated private static var buildSuffix: String? {
        buildSuffix(forBundleID: Bundle.main.bundleIdentifier ?? "")
    }

    /// Phantom is a distinct app from Ghostty and keeps its own config
    /// directory so the two never collide on the same machine — even
    /// though Phantom reads XDG first on macOS same as Ghostty does.
    nonisolated private static func sharedConfigDir() -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let xdgBase = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        let xdg = xdgBase.appendingPathComponent("phantom", isDirectory: true)
        if fm.fileExists(atPath: xdg.path) { return xdg }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.ipetinate.phantom", isDirectory: true)
        if fm.fileExists(atPath: appSupport.appendingPathComponent("config").path) {
            return appSupport
        }

        return xdg
    }

    func string(_ key: String) -> String? {
        values[key]
    }

    // MARK: Theme

    /// Points the theme setting at a theme file Phantom owns.
    ///
    /// Written as an absolute path, not a name: the core resolves a bare
    /// name against its own `themes` directory and its bundle, neither of
    /// which is Phantom's, so a name here fails to load. An absolute path
    /// it loads directly.
    func setTheme(_ theme: TerminalTheme) {
        switch theme.source {
        case .user: set("theme", theme.url.path)
        case .builtin: set("theme", theme.name)
        }
    }

    /// The current theme's display name, for matching against the catalog.
    var currentThemeName: String? {
        guard let value = string("theme"), !value.isEmpty else { return nil }
        guard value.hasPrefix("/") else { return value }
        return (value as NSString).lastPathComponent
    }

    /// The file the theme setting resolves to, by path or by name.
    var currentThemeURL: URL? {
        guard let value = string("theme"), !value.isEmpty else { return nil }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }

        let user = themesDirURL.appendingPathComponent(value)
        if FileManager.default.fileExists(atPath: user.path) { return user }

        return Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
            .appendingPathComponent(value)
    }

    func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let raw = values[key] else { return defaultValue }
        return raw == "true" || raw == "1"
    }

    func double(_ key: String, default defaultValue: Double) -> Double {
        values[key].flatMap(Double.init) ?? defaultValue
    }

    /// Sets (or removes, when nil) a key and persists the file.
    func set(_ key: String, _ value: String?) {
        if let value, !value.isEmpty {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        save()
    }

    /// Posted after settings are applied and the config hot-reloaded.
    static let didApply = Notification.Name("PhantomGuiConfigDidApply")

    /// Persists pending values and hot-reloads the app configuration.
    func apply(ghostty: Ghostty.App) {
        save()
        ghostty.reloadConfig(soft: false)
        NotificationCenter.default.post(name: Self.didApply, object: nil)
    }

    // MARK: Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: guiFileURL.path) else { return }
        values = Self.readGuiValues(in: configDir)
    }

    private func save() {
        Self.writeGuiValues(values, in: configDir)
        Self.ensureIncluded(in: configDir)
    }

    nonisolated private static func readGuiValues(in dir: URL) -> [String: String] {
        let url = dir.appendingPathComponent(fileName)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var parsed: [String: String] = [:]
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            parsed[key] = value
        }
        return parsed
    }

    nonisolated private static func writeGuiValues(_ values: [String: String], in dir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var content = "# Managed by the Ghostty settings window.\n"
        content += "# Manual edits are overwritten; use the main config file instead.\n\n"
        for key in values.keys.sorted() {
            content += "\(key) = \(values[key]!)\n"
        }
        try? content.write(to: dir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    /// Appends the `config-file` include to the main config once.
    nonisolated private static func ensureIncluded(in dir: URL) {
        let url = dir.appendingPathComponent("config")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        let isIncluded = existing.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("config-file") else { return false }
            return trimmed.hasSuffix(fileName)
        }
        guard !isIncluded else { return }

        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
        updated += "config-file = \(fileName)\n"
        try? updated.write(to: url, atomically: true, encoding: .utf8)
    }
}
