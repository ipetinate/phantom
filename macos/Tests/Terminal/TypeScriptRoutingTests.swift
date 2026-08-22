import Foundation
@testable import Ghostty
import Testing

/// Which TypeScript a project has, decided by one file.
///
/// TypeScript 7 is the native rewrite and ships no `tsserver.js`, so
/// `typescript-language-server` — which drives that file and bundles no copy
/// of its own — cannot serve a TS 7 project at all. Measured: `initialize`
/// answers `-32603 Could not find a valid TypeScript installation` and the
/// process exits. The native binary speaks LSP itself instead. So the
/// question "which server" is a fact about the project, and this is where it
/// is answered.
struct TypeScriptToolchainTests {
    /// A `FileManager` that answers for a fixed set of paths, so the routing
    /// can be exercised without laying out real `node_modules` trees.
    private final class FakeFileManager: FileManager, @unchecked Sendable {
        var present: Set<String> = []
        var files: [String: Data] = [:]

        override func fileExists(atPath path: String) -> Bool {
            present.contains(path) || files[path] != nil
        }

        override func contents(atPath path: String) -> Data? { files[path] }
    }

    private let root = "/Users/x/project"

    private var tsserverPath: String {
        root + "/node_modules/typescript/lib/tsserver.js"
    }

    @Test func aProjectWithATsserverGetsTheWrapper() {
        let fileManager = FakeFileManager()
        fileManager.present = [tsserverPath]

        #expect(
            TypeScriptToolchain.resolve(root: root, fileManager: fileManager)
                == .tsserver(path: tsserverPath)
        )
    }

    /// The TypeScript 7 shape: a `typescript` package is installed, and the
    /// one file the wrapper needs is simply not in it.
    @Test func aProjectWhoseTypeScriptHasNoTsserverGetsTheNativeServer() {
        let fileManager = FakeFileManager()
        fileManager.present = [
            root + "/node_modules/typescript/lib/tsc.js",
            root + "/node_modules/typescript/lib/getExePath.js",
        ]

        #expect(TypeScriptToolchain.resolve(root: root, fileManager: fileManager) == .native)
    }

    /// No TypeScript of its own resolves to the native server too — the
    /// useful default rather than a guess, since that is what a global
    /// install puts on `PATH` today. If it is missing as well, the launch
    /// reports `notInstalled` on its own.
    @Test func aProjectWithNoTypeScriptAtAllGetsTheNativeServer() {
        #expect(TypeScriptToolchain.resolve(root: root, fileManager: FakeFileManager()) == .native)
    }

    @Test func thePluginLocationIsAbsoluteAndOnlyWhenInstalled() {
        let fileManager = FakeFileManager()
        #expect(TypeScriptToolchain.vuePluginLocation(root: root, fileManager: fileManager) == nil)

        let location = root + "/node_modules/@vue/typescript-plugin"
        fileManager.present = [location]
        #expect(
            TypeScriptToolchain.vuePluginLocation(root: root, fileManager: fileManager) == location
        )
        #expect(location.hasPrefix("/"), "the plugin resolves location through URI.file")
    }

    @Test func theVersionIsReadOnlyWhenThereIsAMessageToWrite() {
        let fileManager = FakeFileManager()
        #expect(TypeScriptToolchain.localVersion(root: root, fileManager: fileManager) == nil)

        fileManager.files[root + "/node_modules/typescript/package.json"] =
            Data(#"{"name":"typescript","version":"7.0.2"}"#.utf8)
        #expect(TypeScriptToolchain.localVersion(root: root, fileManager: fileManager) == "7.0.2")
    }
}

/// Which servers a file is handed, and — the part with teeth — which it is
/// never handed.
struct TypeScriptRoutingTests {
    @Test func aTypeScriptFileInASixProjectGetsTheWrapper() {
        let servers = LSPServerRegistry.servers(
            forPath: "/p/a.ts",
            toolchain: .tsserver(path: "/p/node_modules/typescript/lib/tsserver.js"),
            tailwind: .absent
        )
        #expect(servers.map(\.command) == ["typescript-language-server"])
    }

    @Test func aTypeScriptFileInASevenProjectGetsTheNativeServer() {
        for path in ["/p/a.ts", "/p/a.tsx", "/p/a.js", "/p/a.jsx", "/p/a.mts", "/p/a.cts"] {
            let servers = LSPServerRegistry.servers(forPath: path, toolchain: .native, tailwind: .absent)
            #expect(
                servers.map(\.command) == [LSPServerRegistry.nativeTypeScriptCommand],
                "\(path) did not route to the native server"
            )
            #expect(servers.first?.arguments == ["--lsp", "--stdio"], "--lsp alone exits 1")
        }
    }

    /// A language the native server has nothing to do with is unaffected by
    /// the project's TypeScript.
    @Test func anUnrelatedLanguageIsNotTouchedByTheToolchain() {
        for toolchain in [TypeScriptToolchain.native, .tsserver(path: "/p/x/tsserver.js")] {
            let servers = LSPServerRegistry.servers(forPath: "/p/main.py", toolchain: toolchain, tailwind: .absent)
            #expect(servers.map(\.command) == ["pyright-langserver"])
        }
    }

    // MARK: .vue

    /// Two servers, since Volar 2 dropped takeover mode: the Vue server for
    /// the template and style, the TypeScript one for the `<script>` block.
    @Test func aVueFileInASixProjectGetsBothServers() {
        let servers = LSPServerRegistry.servers(
            forPath: "/p/App.vue",
            toolchain: .tsserver(path: "/p/node_modules/typescript/lib/tsserver.js"),
            tailwind: .absent
        )
        #expect(servers.map(\.command) == ["vue-language-server", "typescript-language-server"])
    }

    /// The TypeScript half has to introduce itself as `vue`: the plugin's
    /// `languages` array becomes tsserver's `modeIds`, and that is what
    /// registers the server for `vue` at all. It also keeps the two on
    /// separate `LSPCenter` keys — same language, same root, different
    /// command.
    @Test func theTypeScriptHalfOfAVueFileAnnouncesItselfAsVue() {
        let servers = LSPServerRegistry.servers(
            forPath: "/p/App.vue",
            toolchain: .tsserver(path: "/p/node_modules/typescript/lib/tsserver.js"),
            tailwind: .absent
        )
        #expect(servers.allSatisfy { $0.languageID == "vue" })
        #expect(servers.last?.initializationOptionsKind == .vueTypeScriptPlugin)
    }

    /// **Both are routed even in a project that cannot run the second one.**
    ///
    /// Pruning it here was the first shape of this and it produced exactly the
    /// silence the feature exists to remove: a server that is never routed is
    /// never launched, so the sentence explaining why the `<script>` block is
    /// dead — which lives in the `initializationOptions` resolution — never
    /// runs either. The reader got a working template, an empty script, and
    /// nothing to read.
    ///
    /// Routing answers "who serves this language"; launching answers "can it
    /// run here". Only the second question has a voice.
    @Test func aVueFileRoutesBothServersEvenWhenTheProjectCannotRunTheSecond() {
        let servers = LSPServerRegistry.servers(forPath: "/p/App.vue", toolchain: .native, tailwind: .absent)
        #expect(servers.map(\.command) == ["vue-language-server", "typescript-language-server"])
    }

    /// And the refusal it will produce says the three things a reader needs:
    /// which TypeScript is here, that 6.x is what the script half wants, and
    /// that Phantom **will not try** — silence and refusal look identical on
    /// screen, and only one of them is honest.
    @Test func theRefusalReachesTheReaderRatherThanBeingPruned() {
        let outcome = LSPInitializationOptions.vueTypeScriptPlugin(
            root: "/p/definitely-not-a-real-project-\(UUID().uuidString)"
        )

        guard case .failure(let reason) = outcome else {
            Issue.record("a project with no TypeScript resolved plugin options")
            return
        }
        #expect(reason.contains("will not start"))
        #expect(reason.contains("template"))
        #expect(reason.contains("6"))
    }

    // MARK: The one that must never regress

    /// **The native server is never handed a file it does not recognise, and
    /// the reason is that it dies rather than declines.**
    ///
    /// Measured, one `didOpen` per process: `.vue`, `.svelte`, `.astro`,
    /// `.mdx`, `.css` and a file with no extension each end in
    /// `panic: ScriptKind must be specified when parsing source file`, inside
    /// `parser.(*Parser).initializeState`. The process leaves, and everything
    /// else it was serving leaves with it.
    ///
    /// So this is an allowlist, and writing it as "everything except `.vue`"
    /// is the mistake it exists to catch — `.vue` was only the first one
    /// anybody tried. If somebody widens the native entry to a new language
    /// later, this is what tells them why not.
    @Test func nothingOutsideTheMeasuredAllowlistReachesTheNativeServer() {
        let hostile = [
            "/p/App.vue", "/p/App.svelte", "/p/page.astro",
            "/p/notes.mdx", "/p/main.css", "/p/Makefile", "/p/README.md",
        ]

        for path in hostile {
            let servers = LSPServerRegistry.servers(forPath: path, toolchain: .native, tailwind: .absent)
            #expect(
                !servers.contains { $0.command == LSPServerRegistry.nativeTypeScriptCommand },
                """
                \(path) was routed to the native TypeScript server, which panics on any \
                extension outside \(LSPServerRegistry.nativeTypeScriptExtensions.sorted()) — \
                it does not answer empty, it kills the process
                """
            )
        }
    }

    /// The guard that survives a definition this file never wrote.
    ///
    /// The routing table protects the rows *we* author. It cannot protect a
    /// user override that repoints another language's command at `tsc`, nor a
    /// contributed manifest declaring `command: "tsc"` with
    /// `args: ["--lsp", "--stdio"]` — neither definition is written here, so
    /// neither could carry a field saying what it accepts. Both end up with a
    /// command and a path, which is what this asks about.
    @Test func theBinaryIsRefusedTheFileWhoeverPointedAtIt() {
        for path in ["/p/App.vue", "/p/a.svelte", "/p/main.css", "/p/Makefile", "/p/x.ex"] {
            #expect(
                !LSPServerRegistry.accepts(
                    command: LSPServerRegistry.nativeTypeScriptCommand,
                    path: path
                ),
                "\(path) would have been handed to the native server, which panics on it"
            )
        }

        for path in ["/p/a.ts", "/p/a.TSX", "/p/a.js", "/p/tsconfig.json"] {
            #expect(
                LSPServerRegistry.accepts(
                    command: LSPServerRegistry.nativeTypeScriptCommand,
                    path: path
                ),
                "\(path) is in the measured allowlist and was refused"
            )
        }
    }

    /// Every other binary is unaffected. The rule is about one command that
    /// dies on unknown input, not a general permission system — a server that
    /// declines a document politely needs no protection from us.
    @Test func noOtherBinaryIsConstrained() {
        for command in ["typescript-language-server", "vue-language-server", "gopls", "elixir-ls"] {
            for path in ["/p/App.vue", "/p/main.css", "/p/a.ts", "/p/Makefile"] {
                #expect(LSPServerRegistry.accepts(command: command, path: path), "\(command) \(path)")
            }
        }
    }

    /// The other half of the same guard, read off the registry rather than a
    /// list of paths: every language the native entry claims must be one whose
    /// extensions are all in the measured-safe set.
    @Test func theNativeEntryClaimsOnlyMeasuredSafeExtensions() {
        let nativeLanguages = Set(LSPServerRegistry.nativeServers.map(\.languageID))
        #expect(!nativeLanguages.isEmpty, "the native entry vanished from the registry")
        #expect(
            LSPServerRegistry.nativeServers
                .allSatisfy { $0.command == LSPServerRegistry.nativeTypeScriptCommand },
            "a server that is not the native binary was put in the native table"
        )

        for ext in ["vue", "svelte", "astro", "mdx", "css", "md", "py", "rs"] {
            guard let languageID = LSPServerRegistry.languageID(forPath: "f.\(ext)") else { continue }
            #expect(
                !nativeLanguages.contains(languageID),
                ".\(ext) maps to \(languageID), which the native entry claims — it panics on it"
            )
        }

        for ext in LSPServerRegistry.nativeTypeScriptExtensions where ext != "json" {
            let languageID = LSPServerRegistry.languageID(forPath: "f.\(ext)")
            #expect(languageID != nil, ".\(ext) is in the allowlist but maps to no language")
        }
    }
}

/// The options the `<script>` half is started with, and the sentence a reader
/// gets when it cannot be.
struct VueTypeScriptPluginOptionsTests {
    private func value() -> LSPValue {
        LSPInitializationOptions.vuePluginValue(
            tsserverPath: "/p/node_modules/typescript/lib/tsserver.js",
            pluginLocation: "/p/node_modules/@vue/typescript-plugin"
        )
    }

    /// `tsserver.path` is not optional: without it `initialize` answers
    /// "Could not find a valid TypeScript installation" and the process
    /// exits.
    @Test func theOptionsNameTheTsserverAndThePlugin() {
        let options = value()
        #expect(
            options["tsserver"]?["path"]?.stringValue
                == "/p/node_modules/typescript/lib/tsserver.js"
        )

        let plugin = options["plugins"]?.arrayValue?.first
        #expect(plugin?["name"]?.stringValue == "@vue/typescript-plugin")
        #expect(plugin?["location"]?.stringValue == "/p/node_modules/@vue/typescript-plugin")
    }

    /// `languages` becomes tsserver's `modeIds`, which is the thing that
    /// registers the server for `vue`. Without it the server refuses the
    /// document outright.
    @Test func theLanguagesArrayIsWhatRegistersTheServerForVue() {
        let plugin = value()["plugins"]?.arrayValue?.first
        #expect(plugin?["languages"]?.arrayValue?.compactMap(\.stringValue) == ["vue"])
    }

    @Test func theLocationIsAbsolute() {
        let location = value()["plugins"]?.arrayValue?.first?["location"]?.stringValue
        #expect(location?.hasPrefix("/") == true, "location is read through URI.file")
    }

    /// The two failures pull in opposite directions, so they cannot share a
    /// sentence: with no TypeScript the answer is "install one", with
    /// TypeScript 7 it is "install an older one" — which nobody guesses.
    @Test func theTwoFailuresGiveOppositeAdvice() {
        let seven = LSPInitializationOptions.missingVueTypeScriptMessage(foundVersion: "7.0.2")
        #expect(seven.contains("7.0.2"))
        #expect(seven.contains("6.x"))

        let none = LSPInitializationOptions.missingVueTypeScriptMessage(foundVersion: nil)
        #expect(none.contains("no TypeScript of its own"))
        #expect(!none.contains("7.0.2"))
    }

    /// Silence and refusal look identical on screen. A reader who thinks it
    /// was attempted goes hunting for a failure that never happened, so the
    /// message has to say Phantom will not try — and that the rest of the
    /// file still works.
    @Test func theMessageSaysItWillNotTryAndThatTheTemplateStillWorks() {
        let message = LSPInitializationOptions.missingVueTypeScriptMessage(foundVersion: "7.0.2")
        #expect(message.contains("will not start"))
        #expect(message.contains("template"))
    }
}
