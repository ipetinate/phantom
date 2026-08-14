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

    @Test func highlightingAgreesWithTheServerOnTheSameFiles() {
        #expect(CodeLanguage.resolve(fileName: "go.mod") == .go)
        #expect(CodeLanguage.resolve(fileName: "go.sum") == .go)
        #expect(CodeLanguage.resolve(fileName: "main.go") == .go)
        #expect(CodeLanguage.resolve(fileName: "kernel.mod") == .plain)
        #expect(CodeLanguage.resolve(fileName: "deps.sum") == .plain)
    }
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
