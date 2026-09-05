import AppKit
import SwiftUI

/// A parsed terminal theme: enough of the palette to preview and apply.
struct TerminalTheme: Identifiable, Equatable {
    enum Source: Equatable {
        case builtin
        case user
        case contributed(extension: String)

        var sortRank: Int {
            switch self {
            case .user: return 0
            case .contributed: return 1
            case .builtin: return 2
            }
        }
    }

    let name: String
    let source: Source
    let url: URL

    var background: NSColor?
    var foreground: NSColor?
    var cursorColor: NSColor?
    var selectionBackground: NSColor?

    /// The 16 ANSI palette entries, indexed 0-15 where present.
    var palette: [Int: NSColor] = [:]

    var id: String {
        switch source {
        case .builtin: return "builtin:" + name
        case .user: return "user:" + name
        case .contributed(let extensionName): return "extension:" + extensionName + ":" + name
        }
    }

    /// The first 8 ANSI colors, for the preview swatch strip.
    var previewColors: [NSColor] {
        (0..<8).compactMap { palette[$0] }
    }
}

/// Discovers and parses themes from the app bundle, the user's config
/// directory, and the extensions the language catalog has installed.
/// Parsing happens once, off the main thread.
@MainActor
final class ThemeCatalog: ObservableObject {
    @Published private(set) var themes: [TerminalTheme] = []
    @Published private(set) var isLoading = false

    private let userThemesDirs: [URL]

    /// - Parameter userThemesDirs: nearest first. A second build reads its own
    ///   directory and then the reader's, because its own starts empty — see
    ///   `GuiConfigStore.themeSearchDirs`.
    init(userThemesDirs: [URL]) {
        self.userThemesDirs = userThemesDirs
    }

    private static var builtinThemesDir: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
    }

    func loadIfNeeded() {
        guard themes.isEmpty, !isLoading else { return }
        reload()
    }

    func reload() {
        isLoading = true
        let builtinDir = Self.builtinThemesDir
        let userDirs = userThemesDirs
        let contributed = LanguageResolver.shared.catalog.themes

        Task.detached(priority: .userInitiated) {
            var result: [TerminalTheme] = []

            if let builtinDir {
                result += Self.scan(dir: builtinDir, source: .builtin)
            }
            /// Nearest first, and one name wins once: a build that has its
            /// own copy of a theme shows that one, not both.
            var seen = Set<String>()
            for dir in userDirs {
                for theme in Self.scan(dir: dir, source: .user)
                where seen.insert(theme.name).inserted {
                    result.append(theme)
                }
            }
            for entry in contributed {
                guard let theme = Self.parse(
                    url: entry.theme.fileURL,
                    source: .contributed(extension: entry.extensionName),
                    name: entry.theme.name
                ), seen.insert(theme.name).inserted
                else { continue }
                result.append(theme)
            }

            result.sort {
                ($0.source.sortRank, $0.name.lowercased())
                    < ($1.source.sortRank, $1.name.lowercased())
            }

            let themes = result
            await MainActor.run { [weak self] in
                self?.themes = themes
                self?.isLoading = false
            }
        }
    }

    nonisolated private static func scan(dir: URL, source: TerminalTheme.Source) -> [TerminalTheme] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        return entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return nil }
            return parse(url: url, source: source)
        }
    }

    nonisolated static func parse(
        url: URL,
        source: TerminalTheme.Source,
        name: String? = nil
    ) -> TerminalTheme? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var theme = TerminalTheme(name: name ?? url.lastPathComponent, source: source, url: url)

        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "background": theme.background = NSColor(hex: value)
            case "foreground": theme.foreground = NSColor(hex: value)
            case "cursor-color": theme.cursorColor = NSColor(hex: value)
            case "selection-background": theme.selectionBackground = NSColor(hex: value)
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1)
                guard parts.count == 2,
                      let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                      let color = NSColor(hex: parts[1].trimmingCharacters(in: .whitespaces))
                else { continue }
                theme.palette[index] = color
            default: continue
            }
        }

        return theme
    }
}

