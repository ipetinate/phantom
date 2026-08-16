import Foundation
@testable import Ghostty
import Testing

/// The editor engine must stay extractable into its own package.
///
/// That promise is easy to make and easy to break — one `ThemePalette.shared`
/// reached for in a hurry and the directory can never leave. So instead of
/// a comment nobody rereads, this reads the engine's own source and fails
/// on anything that would tie it to Phantom.
///
/// The rule: **the engine takes what it needs as values.** A theme arrives
/// as `CodeTheme`, configuration as `CodeEditorConfiguration`. Nothing in
/// there asks the app a question.
struct EditorEngineBoundaryTests {
    /// Symbols that would tie the engine to this app.
    ///
    /// `UserDefaults` is on the list for the same reason as the singletons:
    /// a component that reads preferences behind the host's back can't be
    /// configured by a different host.
    ///
    /// The language-extension entries are on it for a reason worth spelling
    /// out, and `LanguageTrust` is written as a prefix so the store and the
    /// alert are covered too: a language contributed by a file on disk
    /// reaches the engine as a `LanguageSyntax` — validated, escaped, and
    /// carrying no path — and the shortcut of reading the manifest or the
    /// catalog directly from the highlighter would work, once, and take the
    /// validation with it.
    ///
    /// `CompletionSettings` is a prefix for the same reason, and covers the
    /// store as well as the value. The completion preferences are keyed by
    /// **language id**, and the engine has no idea what language it is
    /// showing — so the host has to collapse "completion is on, and on for
    /// this language" into the single `Bool` that crosses as
    /// `CodeEditorConfiguration.completionEnabled`. An engine that could
    /// name the store would resolve the language itself, and the one place
    /// that decision is made would become two.
    private static let forbidden = [
        "CompletionSettings",
        "ThemePalette",
        "LanguageCatalog",
        "LanguageManifest",
        "LanguageResolver",
        "LanguageTrust",
        "LSPServerRegistry",
        "CompletionBridge",
        "CompletionKindMapping",
        "CompletionIconFont",
        "SidebarGroupStore",
        "SidebarTabModel",
        "SidebarTabManager",
        "FileIconProvider",
        "GitCenter",
        "Ghostty.",
        "UserDefaults",
        "GuiConfigStore",
        "TerminalController",
        "AppDelegate",
    ]

    /// Located from this file rather than the bundle: the sources aren't
    /// copied into the test bundle, and the point is to inspect the code as
    /// written.
    private var engineDirectory: URL {
        URL(fileURLWithPath: #filePath)          // …/macos/Tests/Terminal/<this>.swift
            .deletingLastPathComponent()          // …/macos/Tests/Terminal
            .deletingLastPathComponent()          // …/macos/Tests
            .deletingLastPathComponent()          // …/macos
            .appendingPathComponent("Sources/Features/Terminal/Editor/Engine")
    }

    /// Every Swift file under the engine, **at any depth**.
    ///
    /// It used to list the directory shallowly, which made the whole guard
    /// opt-out by accident: a file in `Engine/Diff/` or `Engine/Markdown/`
    /// was never read, so it could name anything it liked and stay green.
    /// Nobody had subdirectories there yet, which is exactly why it went
    /// unnoticed — the hole would have opened under the first person to add
    /// one, and the check would have kept reporting success.
    ///
    /// An enumerator rather than a recursive listing, because it also skips
    /// package directories, which is what stops a stray `.xcassets` from
    /// being read as source.
    private func engineSources() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: engineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        guard let enumerator else { return [] }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    /// Guards the guard: a wrong path would make every check below pass by
    /// finding nothing.
    @Test func theEngineDirectoryIsWhereWeThinkItIs() throws {
        let sources = try engineSources()
        #expect(!sources.isEmpty, "no engine sources at \(engineDirectory.path)")
    }

    /// Comments are dropped before scanning.
    ///
    /// Prose gets to *name* these things — explaining that the engine takes
    /// a theme as a value rather than reaching for the app's is exactly the
    /// kind of comment worth having, and a check that forbade saying so
    /// would push the explanation out of the file it explains.
    private func code(in source: URL) throws -> String {
        try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*")
                    && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    @Test func theEngineNamesNothingFromPhantom() throws {
        for source in try engineSources() {
            let text = try code(in: source)
            for symbol in Self.forbidden {
                #expect(
                    !text.contains(symbol),
                    "\(source.lastPathComponent) references \(symbol); the engine has to receive that as a value instead, or it can never be extracted"
                )
            }
        }
    }

    /// AppKit and Foundation are the floor a text engine stands on; SwiftUI
    /// is allowed for the view wrapper.
    ///
    /// Anything *not* here is a dependency somebody would have to justify
    /// at extraction time, which is the moment this test exists to make
    /// loud. Tree-sitter will earn its place on this list when it lands;
    /// until then the engine carries nothing.
    @Test func theEngineImportsOnlyItsOwnDependencies() throws {
        let allowed: Set<String> = ["Foundation", "AppKit", "SwiftUI", "CoreText", "os"]

        for source in try engineSources() {
            let text = try String(contentsOf: source, encoding: .utf8)
            for line in text.split(separator: "\n") where line.hasPrefix("import ") {
                let module = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                #expect(
                    allowed.contains(module),
                    "\(source.lastPathComponent) imports \(module)"
                )
            }
        }
    }
}
