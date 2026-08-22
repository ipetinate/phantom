import AppKit
import Foundation
@testable import Ghostty
import Testing

/// The registry is a table, so these are table invariants.
///
/// The one that matters operationally is the install hint: none of these
/// servers is installed by default, so an entry without a usable hint turns
/// into a UI that says a language is unsupported on a machine where one
/// `npm i -g` would have fixed it.
struct LSPServerRegistryTests {
    @Test func everyEntryHasACommand() {
        for definition in LSPServerRegistry.all {
            #expect(!definition.languageID.isEmpty)
            #expect(!definition.displayName.isEmpty)
            #expect(!definition.command.isEmpty, "\(definition.languageID) has no command")
            #expect(!definition.command.contains(" "), "\(definition.languageID) packs args into the command")
        }
    }

    @Test func everyEntryHasAnInstallHint() {
        for definition in LSPServerRegistry.all {
            #expect(!definition.installHint.isEmpty, "\(definition.languageID) has no install hint")
        }
    }

    /// Arguments are passed to `Process` one at a time, so a single string
    /// holding `"--stdio --log"` would be handed over as one argument and
    /// rejected by the server.
    @Test func argumentsAreIndividualTokens() {
        for definition in LSPServerRegistry.all {
            for argument in definition.arguments {
                #expect(!argument.isEmpty, "\(definition.languageID) has an empty argument")
                #expect(!argument.contains(" "), "\(definition.languageID) has an unsplit argument")
            }
        }
    }

    @Test func languageIDsAreUnique() {
        let ids = LSPServerRegistry.all.map(\.languageID)

        #expect(Set(ids).count == ids.count)
    }

    @Test func anUnknownLanguageHasNoServer() {
        #expect(LSPServerRegistry.server(forLanguage: "brainfuck") == nil)
        #expect(LSPServerRegistry.server(forLanguage: "") == nil)
    }

    @Test func theExpectedLanguagesAreCovered() throws {
        let expected = [
            "typescript", "javascript", "vue", "swift", "kotlin",
            "python", "rust", "go", "json", "yaml"
        ]

        for languageID in expected {
            let definition = try #require(
                LSPServerRegistry.server(forLanguage: languageID),
                "no server for \(languageID)"
            )
            #expect(definition.languageID == languageID)
        }
    }

    @Test func theStdioServersAskForStdio() throws {
        for languageID in ["typescript", "javascript", "vue", "python", "json", "yaml"] {
            let definition = try #require(LSPServerRegistry.server(forLanguage: languageID))
            #expect(definition.arguments.contains("--stdio"), "\(languageID) does not request stdio")
        }
    }

    @Test func typeScriptAndJavaScriptShareOneServer() throws {
        let typescript = try #require(LSPServerRegistry.server(forLanguage: "typescript"))
        let javascript = try #require(LSPServerRegistry.server(forLanguage: "javascript"))
        let react = try #require(LSPServerRegistry.server(forLanguage: "typescriptreact"))

        #expect(typescript.command == "typescript-language-server")
        #expect(javascript.command == typescript.command)
        #expect(react.command == typescript.command)
        #expect(javascript.installHint == typescript.installHint)
    }

    /// Language ids are matched case-insensitively because they arrive from
    /// configuration and from file-type detection, neither of which agrees
    /// on casing.
    @Test func languageLookupIgnoresCase() {
        #expect(LSPServerRegistry.server(forLanguage: "Swift")?.command == "sourcekit-lsp")
        #expect(LSPServerRegistry.server(forLanguage: "TypeScript")?.languageID == "typescript")
    }

    @Test func pathsMapToTheirLanguage() {
        #expect(LSPServerRegistry.languageID(forPath: "/tmp/a/index.ts") == "typescript")
        #expect(LSPServerRegistry.languageID(forPath: "App.tsx") == "typescriptreact")
        #expect(LSPServerRegistry.languageID(forPath: "/x/HomeView.vue") == "vue")
        #expect(LSPServerRegistry.languageID(forPath: "GitStatus.SWIFT") == "swift")
        #expect(LSPServerRegistry.languageID(forPath: "build.zig") == "zig")
        #expect(LSPServerRegistry.languageID(forPath: "go.mod") == "go")
        #expect(LSPServerRegistry.languageID(forPath: "go.sum") == "go")
        #expect(LSPServerRegistry.languageID(forPath: "docker-compose.yml") == "yaml")
    }

    /// Most files a terminal opens have no language server, and that is the
    /// normal case rather than a failure.
    @Test func pathsWithNoKnownLanguageResolveToNothing() {
        #expect(LSPServerRegistry.languageID(forPath: "Makefile") == nil)
        #expect(LSPServerRegistry.languageID(forPath: "/etc/hosts") == nil)
        #expect(LSPServerRegistry.server(forPath: "notes.txt") == nil)
    }

    @Test func aPathResolvesAllTheWayToItsServer() throws {
        let definition = try #require(LSPServerRegistry.server(forPath: "src/main.rs"))

        #expect(definition.command == "rust-analyzer")
        #expect(definition.installHint == "rustup component add rust-analyzer")
    }

    /// The list an "install these" UI would show: one row per binary, not
    /// one per language id.
    @Test func distinctServersCollapseSharedBinaries() {
        let commands = LSPServerRegistry.distinctServers.map(\.command)

        #expect(Set(commands).count == commands.count)
        #expect(commands.filter { $0 == "typescript-language-server" }.count == 1)
        #expect(commands.count < LSPServerRegistry.all.count)
    }

    @Test func invocationReadsAsACommandLine() throws {
        let typescript = try #require(LSPServerRegistry.server(forLanguage: "typescript"))
        let swift = try #require(LSPServerRegistry.server(forLanguage: "swift"))

        #expect(typescript.invocation == "typescript-language-server --stdio")
        #expect(swift.invocation == "sourcekit-lsp")
    }

    /// Volar is the one server that needs to be told where TypeScript
    /// lives; everyone else sends nothing at all.
    @Test func onlyVueResolvesInitializationOptions() throws {
        let vue = try #require(LSPServerRegistry.server(forLanguage: "vue"))
        #expect(vue.initializationOptionsKind == .vueTypeScriptSDK)

        for definition in LSPServerRegistry.all where definition.languageID != "vue" {
            #expect(
                definition.initializationOptionsKind == .none,
                "\(definition.languageID) shouldn't need initializationOptions"
            )
        }
    }

    /// Every server gets a category. An unclassified default exists, but a
    /// registry entry that falls into it is a review miss, not a choice.
    @Test func everyServerHasACategory() {
        for definition in LSPServerRegistry.all {
            switch definition.command {
            case "typescript-language-server", "vue-language-server",
                 "pyright-langserver", "bash-language-server",
                 "intelephense", "ruby-lsp", "tsc":
                #expect(definition.category == .script, "\(definition.command)")
            case "sourcekit-lsp", "kotlin-language-server", "rust-analyzer",
                 "gopls", "zls", "jdtls", "clangd":
                #expect(definition.category == .compiled, "\(definition.command)")
            case "vscode-html-language-server", "marksman":
                #expect(definition.category == .markup, "\(definition.command)")
            case "vscode-css-language-server":
                #expect(definition.category == .styles, "\(definition.command)")
            case "vscode-json-language-server", "yaml-language-server":
                #expect(definition.category == .data, "\(definition.command)")
            case "terraform-ls":
                #expect(definition.category == .infrastructure, "\(definition.command)")
            default:
                Issue.record("\(definition.command) falls into the default category")
            }
        }
    }

    /// `uninstallCommand` switches on the *binary*, and the three servers
    /// that ship inside `vscode-langservers-extracted` are three separate
    /// binaries. The case was written against the package name instead, so
    /// it matched no server at all and CSS, HTML and JSON each got a
    /// permanently disabled Uninstall button.
    @Test func theServersSharingAnNpmPackageCanBeUninstalled() {
        for command in [
            "vscode-css-language-server",
            "vscode-html-language-server",
            "vscode-json-language-server",
        ] {
            let server = LSPServerRegistry.all.first { $0.command == command }
            #expect(server?.uninstallCommand == "npm rm -g vscode-langservers-extracted", "\(command)")
        }
    }

    /// The general form of the same bug: anything this offers to install
    /// with a package manager can be removed with one. The servers that
    /// legitimately have no inverse — `go install`, and the two that ship
    /// with Xcode — are listed rather than inferred, so adding a server
    /// without an uninstall is a decision somebody has to write down.
    @Test func everyPackageManagedServerCanBeUninstalled() {
        let withoutAnInverse: Set<String> = ["gopls", "sourcekit-lsp", "clangd"]

        for definition in LSPServerRegistry.distinctServers {
            guard !withoutAnInverse.contains(definition.command) else {
                #expect(definition.uninstallCommand == nil, "\(definition.command)")
                continue
            }
            #expect(
                definition.uninstallCommand != nil,
                "\(definition.command) can be installed but never removed"
            )
        }
    }

    /// Two language ids that share a binary must agree on the category — the
    /// settings list groups by binary, so a disagreement would split one
    /// row across two sections.
    @Test func sharedBinariesAgreeOnCategory() {
        let byCommand: [String: Set<LSPServerCategory>] = Dictionary(
            grouping: LSPServerRegistry.all,
            by: \.command
        ).mapValues { Set($0.map(\.category)) }

        for (command, categories) in byCommand {
            #expect(categories.count == 1, "\(command) spans \(categories.count) categories")
        }
    }
}

/// The logos beside the rows, which nothing checked until now.
///
/// A logo is looked up by asset name, and a name that is not in the catalogue
/// draws **nothing** — no crash, no warning, an 18-point hole in the list. It
/// is the same failure as naming an SF Symbol that does not exist, and the same
/// way to catch it: ask the bundle.
@MainActor
struct LanguageIconAssetTests {
    @Test func everyLogoTheListCanAskForIsInTheCatalogue() {
        var names: Set<String> = []

        for definition in LSPServerRegistry.distinctServers + LSPServerRegistry.tailwindServers {
            if let name = definition.languageIconName { names.insert(name) }
        }
        for definition in LSPServerRegistry.all {
            if let name = definition.languageIconName { names.insert(name) }
        }

        #expect(names.count > 15, "expected the whole set of logos, got \(names.count)")

        for name in names.sorted() {
            #expect(NSImage(named: name) != nil, "\(name) is not in Assets.xcassets")
        }
    }

    /// Tailwind's row is the reason the lookup asks the command first: it is
    /// registered under five language ids it does not own, so by language alone
    /// it drew the logo of the server listed above it.
    @Test func tailwindUsesItsOwnLogoAndNotItsLanguages() {
        for definition in LSPServerRegistry.tailwindServers {
            #expect(definition.languageIconName == "Lang-tailwind", "\(definition.languageID)")
        }

        #expect(LSPServerRegistry.server(forLanguage: "html")?.languageIconName == "Lang-html")
    }
}

/// The two TypeScript rows, which are two because a project's TypeScript
/// decides which server can serve it, and a reader has to be able to tell them
/// apart and install either one.
struct TypeScriptRowTests {
    private var wrapper: LSPServerDefinition? {
        LSPServerRegistry.distinctServers.first { $0.command == "typescript-language-server" }
    }

    private var native: LSPServerDefinition? {
        LSPServerRegistry.distinctServers.first { $0.command == "tsc" }
    }

    @Test func bothAreListedAndSayWhichTheyAre() throws {
        let wrapper = try #require(wrapper)
        let native = try #require(native)

        #expect(wrapper.displayName != native.displayName)
        #expect(native.displayName.contains("7"), "\(native.displayName)")
        #expect(native.displayName.contains("Go"), "\(native.displayName)")
        #expect(wrapper.displayName.contains("npm"), "\(wrapper.displayName)")
    }

    /// **The crossing that was reported.** The wrapper's install used to carry
    /// a global `typescript@6`, and the native server *is* the `typescript`
    /// package at 7 — so installing either row changed the other, and
    /// uninstalling one could take the other's TypeScript with it.
    @Test func theirPackagesDoNotOverlap() throws {
        let wrapper = try #require(wrapper)
        let native = try #require(native)

        func packages(_ command: String?) -> Set<String> {
            guard let command else { return [] }
            let words = command.split(separator: " ").map(String.init)
            return Set(words.dropFirst(3).map { $0.split(separator: "@").first.map(String.init) ?? $0 })
        }

        let wrapperPackages = packages(wrapper.installCommand).union(packages(wrapper.uninstallCommand))
        let nativePackages = packages(native.installCommand).union(packages(native.uninstallCommand))

        #expect(!wrapperPackages.isEmpty)
        #expect(!nativePackages.isEmpty)
        #expect(
            wrapperPackages.isDisjoint(with: nativePackages),
            "\(wrapperPackages) overlaps \(nativePackages)"
        )
    }

    /// A row with a dependency plan draws the multi-package popover *and* an
    /// Uninstall button beside it. Neither TypeScript row wants that: each is
    /// one package, installed and removed on its own.
    @Test func neitherRowNeedsTheMultiPackagePopover() throws {
        #expect(try #require(wrapper).dependencyPlan == nil)
        #expect(try #require(native).dependencyPlan == nil)
    }

    /// Both installed is a normal state, not a conflict: which one serves a
    /// file is decided per project by whether it has a `tsserver.js`.
    @Test func bothInstalledIsNotAConflict() {
        let withLocal = TypeScriptToolchain.tsserver(path: "/p/node_modules/typescript/lib/tsserver.js")

        let served = LSPServerRegistry.servers(forPath: "/p/a.ts", toolchain: withLocal, tailwind: .absent)
        #expect(served.map(\.command) == ["typescript-language-server"])

        let alone = LSPServerRegistry.servers(forPath: "/p/a.ts", toolchain: .native, tailwind: .absent)
        #expect(alone.map(\.command) == ["tsc"])
    }
}

/// The order the Languages pane puts things in.
///
/// The pane sorts both levels itself, so these pin the inputs that sort has
/// to work with rather than the view — a `private var` in a `View` is not
/// reachable from here, and reaching for it would test the wrong thing
/// anyway.
struct LanguageListOrderTests {
    /// Alphabetical by header, so a reader hunting for a section scans
    /// instead of learning somebody's idea of importance. Pinned as a
    /// literal because the sort key is the *title*, not the case name — the
    /// two disagree for every case, and sorting the wrong one still
    /// produces a plausible-looking list.
    @Test func theHeadersAreAlphabetical() {
        let sorted = LSPServerCategory.allCases
            .map(\.title)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        #expect(sorted == ["Compiled", "Data", "Infrastructure", "Markup", "Script", "Styles"])
    }

    /// The complaint that prompted the sort: the two TypeScript servers sat
    /// seven rows apart in one section, because the registry lists them in
    /// the order they were added.
    @Test func theTwoTypeScriptRowsEndUpAdjacent() throws {
        let script = LSPServerRegistry.distinctServers
            .filter { $0.category == .script }
            .map(\.displayName)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        let first = try #require(script.firstIndex { $0.hasPrefix("TypeScript") })
        let last = try #require(script.lastIndex { $0.hasPrefix("TypeScript") })

        #expect(last - first == 1, "\(script)")
    }

    /// `localizedStandardCompare`, not `<`. A plain comparison orders by
    /// scalar value, which puts "(" before a digit and would separate the
    /// two rows above by whatever else happens to start with "TypeScript".
    @Test func digitsSortAsNumbersRatherThanCharacters() {
        let names = ["TypeScript 10 (Go)", "TypeScript 7 (Go)", "TypeScript (npm)"]
        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        #expect(sorted.firstIndex(of: "TypeScript 7 (Go)")! < sorted.firstIndex(of: "TypeScript 10 (Go)")!)
    }
}
