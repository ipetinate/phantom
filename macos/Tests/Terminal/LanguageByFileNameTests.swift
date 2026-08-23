import Foundation
@testable import Ghostty
import Testing

/// Files whose name decides the language, and — the point of these — the
/// files that merely share their extension and must not be caught.
///
/// `go.mod` and `go.sum` were matched on `.mod` and `.sum`, which belong to
/// plenty of things that are not Go: a Fortran module, a checksum list, a
/// synthesizer patch. Every one of them started gopls and was painted with
/// Go's syntax.
struct LanguageByFileNameTests {
    @Test func goManifestsResolveToGo() {
        #expect(LSPServerRegistry.languageID(forPath: "/p/go.mod") == "go")
        #expect(LSPServerRegistry.languageID(forPath: "/p/go.sum") == "go")
        #expect(LSPServerRegistry.languageID(forPath: "/p/go.work") == "go")
    }

    @Test func otherFilesSharingTheExtensionAreNotGo() {
        #expect(LSPServerRegistry.languageID(forPath: "/p/kernel.mod") == nil)
        #expect(LSPServerRegistry.languageID(forPath: "/p/deps.sum") == nil)
        #expect(LSPServerRegistry.languageID(forPath: "/p/patch.mod") == nil)
    }

    @Test func aRealGoSourceFileIsStillGo() {
        #expect(LSPServerRegistry.languageID(forPath: "/p/main.go") == "go")
    }

    /// The JSON family of dotfiles, which have no extension at all rather
    /// than one that belongs to somebody else.
    @Test func extensionlessRCFilesResolveToJSON() {
        for name in LanguageByFileNameTests.jsonRCFiles {
            #expect(
                LSPServerRegistry.languageID(forPath: "/p/\(name)") == "json",
                "\(name) did not resolve to JSON"
            )
        }
    }

    @Test func thoseRCFilesGetTheJSONServer() throws {
        let server = try #require(LSPServerRegistry.server(forPath: "/p/.prettierrc"))

        #expect(server.command == "vscode-json-language-server")
    }

    /// The escape hatch for the files that are allowed to be YAML: spell the
    /// extension and the extension table answers, with nothing needed in the
    /// name table.
    @Test func spellingTheExtensionOverridesTheNameEntirely() {
        #expect(LSPServerRegistry.languageID(forPath: "/p/.prettierrc.yaml") == "yaml")
        #expect(LSPServerRegistry.languageID(forPath: "/p/.prettierrc.yml") == "yaml")
        #expect(LSPServerRegistry.languageID(forPath: "/p/.prettierrc.json") == "json")
        #expect(CodeLanguage.resolve(fileName: ".prettierrc.yaml") == .yaml)
        #expect(CodeLanguage.resolve(fileName: ".prettierrc.json") == .json)
    }

    /// `.npmrc` lives in the same folder as the rest of them and is INI, so
    /// it gets neither the JSON server nor JSON's colours.
    @Test func npmrcIsNotJSON() {
        #expect(LSPServerRegistry.languageID(forPath: "/p/.npmrc") == nil)
        #expect(CodeLanguage.resolve(fileName: ".npmrc") == .plain)
    }

    @Test func highlightingAgreesWithTheServerOnTheSameFiles() {
        #expect(CodeLanguage.resolve(fileName: "go.mod") == .go)
        #expect(CodeLanguage.resolve(fileName: "go.sum") == .go)
        #expect(CodeLanguage.resolve(fileName: "main.go") == .go)
        #expect(CodeLanguage.resolve(fileName: "kernel.mod") == .plain)
        #expect(CodeLanguage.resolve(fileName: "deps.sum") == .plain)

        for name in LanguageByFileNameTests.jsonRCFiles {
            #expect(
                LSPServerRegistry.languageID(forPath: "/p/\(name)") == "json",
                "the server does not call \(name) JSON"
            )
            #expect(
                CodeLanguage.resolve(fileName: name) == .json,
                "the highlighter does not call \(name) JSON"
            )
        }
    }

    /// Named files this build calls JSON. `.prettierrc`, `.babelrc` and
    /// `.eslintrc` may each legally hold YAML — see the note on
    /// `languageIDByFileName` for why they are called JSON regardless.
    static let jsonRCFiles = [
        ".prettierrc", ".babelrc", ".eslintrc", ".jscsrc", ".jshintrc", ".swcrc",
    ]
}

/// Round-tripping a shortcut whose key is itself the separator.
///
/// `+` is an ordinary key, and the serialized form joins with `+`, so ⌘+
/// wrote "command++" and read back as "command" with no key — the binding
/// silently reverted to its default on the next launch.
struct PhantomShortcutPlusKeyTests {
    @Test func aPlusKeyRoundTrips() throws {
        let shortcut = PhantomShortcut(key: "+", modifiers: [.command])
        let restored = try #require(PhantomShortcut(serialized: shortcut.serialized))

        #expect(restored.key == "+")
        #expect(restored.modifiers == [.command])
    }

    @Test func aPlusKeyWithSeveralModifiersRoundTrips() throws {
        let shortcut = PhantomShortcut(key: "+", modifiers: [.command, .shift])
        let restored = try #require(PhantomShortcut(serialized: shortcut.serialized))

        #expect(restored.key == "+")
        #expect(restored.modifiers == [.command, .shift])
    }

    @Test func ordinaryKeysStillRoundTrip() throws {
        for key in ["n", "a", "1", "["] {
            let shortcut = PhantomShortcut(key: key, modifiers: [.command, .shift])
            let restored = try #require(
                PhantomShortcut(serialized: shortcut.serialized),
                "\(key) did not survive"
            )
            #expect(restored.key == key)
            #expect(restored.modifiers == [.command, .shift])
        }
    }

    @Test func aBadModifierIsStillRefused() {
        #expect(PhantomShortcut(serialized: "hyper+n") == nil)
        #expect(PhantomShortcut(serialized: "command+shiftt+n") == nil)
    }
}
