import Foundation

/// The kind of language a server's workspace deals in, used to group the
/// settings list into readable sections.
///
/// Deliberately coarser than "one category per server": the point of the
/// grouping is that a user scanning for "the Python server" or "the one for
/// C" can land in the right neighborhood without reading every row.
enum LSPServerCategory: String, CaseIterable, Hashable, Sendable, Identifiable {
    /// Interpreted or just-in-time languages whose sources run as-is.
    case script

    /// Languages that are compiled to native code or bytecode before
    /// running.
    case compiled

    /// HTML, Markdown and friends — structured text for documents.
    case markup

    /// The frameworks that put a language inside a file of their own —
    /// `.vue`, `.svelte`, `.astro`. Their servers are not script servers
    /// even though the file holds script: one file carries a template, a
    /// style block and a script block, and it takes two processes to serve.
    /// Filing them under Script hid the fact that they behave differently
    /// from every row there.
    case frontendFramework

    /// CSS and its preprocessors.
    case styles

    /// JSON, YAML and other structured data.
    case data

    /// Infrastructure-as-code.
    case infrastructure

    var id: String { rawValue }

    /// The section header shown in Settings.
    ///
    /// The sections are ordered by this string, not by the order the cases
    /// are declared in — so a reader hunting for one scans alphabetically
    /// instead of learning which family somebody decided was important.
    var title: String {
        switch self {
        case .script: return "Script"
        case .frontendFramework: return "Frontend Frameworks"
        case .compiled: return "Compiled"
        case .markup: return "Markup"
        case .styles: return "Styles"
        case .data: return "Data"
        case .infrastructure: return "Infrastructure"
        }
    }

    /// An SF Symbol for the section header, when the row icon isn't enough
    /// to distinguish one section from the next.
    var systemImage: String {
        switch self {
        case .script: return "chevron.left.forwardslash.chevron.right"
        case .frontendFramework: return "square.stack.3d.up"
        case .compiled: return "hammer"
        case .markup: return "doc.richtext"
        case .styles: return "paintbrush"
        case .data: return "tablecells"
        case .infrastructure: return "server.rack"
        }
    }
}

/// How to start one language server, and what to tell the user when it
/// isn't there.
struct LSPServerDefinition: Hashable, Sendable, Identifiable {
    /// The LSP `languageId`, spelled exactly as the specification does —
    /// it is also what goes in every `textDocument/didOpen`, so inventing a
    /// nicer name here would mean translating it back later.
    let languageID: String

    /// For the "install this" row in the UI.
    let displayName: String

    /// Looked up on the login shell's `PATH`, not launched through a shell.
    let command: String

    let arguments: [String]

    /// Almost none of these are installed on a given machine, and a server
    /// that fails to spawn is indistinguishable from one that is broken
    /// unless the UI can say *what* is missing and *how* to get it. The
    /// hint travels with the definition so no view has to keep its own
    /// table of them in sync.
    let installHint: String

    /// How to resolve `initializationOptions` for this language, absent a
    /// user override. See `LSPInitializationOptions`.
    var initializationOptionsKind: LSPInitializationOptionsKind = .none

    /// Where this definition came from, and therefore whether starting it
    /// needs to be asked about. See `LSPServerOrigin`.
    ///
    /// Defaulted so the table below is untouched, and a field rather than a
    /// lookup on the side because a field that travels with the value cannot
    /// be forgotten — a table consulted by language id can be, and one
    /// missed consultation is not a UI defect, it is the trust gate not
    /// running.
    ///
    /// This does put provenance into a type whose own comment (below, on
    /// `LSPServerRegistry`) says it has none. That comment is about the
    /// *registry*, which still reads nothing and asks nobody; this field is
    /// data the caller supplies, and the alternative — a definition that
    /// cannot say where it came from — is what makes the gate skippable.
    var origin: LSPServerOrigin = .builtIn

    /// The newest Java feature version this server is known to run on, for
    /// servers that run on a JVM at all.
    ///
    /// A ceiling, not a requirement: it exists because a server can bundle a
    /// compiler older than the JDK the developer builds with, and inheriting
    /// `JAVA_HOME` then kills it at launch. `LSPJavaRuntime` reads this to
    /// decide whether to hand the server a different JVM than the one the
    /// environment named.
    ///
    /// Nil — the default, and the answer for every server here that isn't
    /// Java — means the environment is passed through as-is.
    var maximumJavaFeatureVersion: Int?

    var id: String { languageID }

    /// Which section of the Settings list this server belongs to. Keyed off
    /// the command so shared binaries (one server, four language ids) land
    /// in one place and can't disagree about it.
    var category: LSPServerCategory {
        switch command {
        case "typescript-language-server", "tsc",
             "pyright-langserver", "bash-language-server",
             "intelephense", "ruby-lsp":
            return .script
        case "vue-language-server":
            /// Its own section rather than Script, even though a `.vue` holds
            /// script. The row behaves unlike every other one under Script: a
            /// single file carries a template, a style block and a script
            /// block, and serving it takes two processes — this server and
            /// `typescript-language-server` loading `@vue/typescript-plugin`.
            /// Filing it with the script servers hid exactly the thing a
            /// reader comes to this row to understand.
            ///
            /// `typescript-language-server` stays under Script even though it
            /// is the second half of a `.vue`. It is keyed by command, as the
            /// note above says, and its own home is TypeScript.
            return .frontendFramework
        case "sourcekit-lsp", "kotlin-language-server", "rust-analyzer",
             "gopls", "zls", "jdtls", "clangd":
            return .compiled
        case "vscode-html-language-server", "marksman":
            return .markup
        case "vscode-css-language-server", LSPServerRegistry.tailwindCommand:
            /// Tailwind sits with CSS rather than with the script servers it
            /// shares language ids with: what it completes is a stylesheet's
            /// vocabulary, and the reader looking for it is looking for the
            /// styling tool. Without this it fell to the `default` below and
            /// listed itself under Script, which is where the comment there
            /// says an unclassified server ends up.
            return .styles
        case "vscode-json-language-server", "yaml-language-server", "taplo":
            return .data
        case "terraform-ls":
            return .infrastructure
        default:
            // A future server that forgot to be classified is more visible
            // as a Script than as a compiler error, but the UI groups by
            // category, so an unclassified server is exactly as lost as its
            // author was. Keeping a default lets new servers ship without a
            // one-line diff in a switch, and `.script` is the largest group.
            return .script
        }
    }

    /// What a "not installed" message should quote back.
    var invocation: String {
        ([command] + arguments).joined(separator: " ")
    }

    /// The executable command shown and copied by Settings. Some servers
    /// ship with a toolchain, so their install hint also contains prose.
    ///
    /// **Empty for anything a manifest contributed**, and that refusal is
    /// the reason to read this property at all. The `default` branch below
    /// hands back `installHint`, and Settings passes what it gets to
    /// `$SHELL -lic` — the one place in this app where a string becomes a
    /// shell command. For a contributed definition `installHint` is *the
    /// manifest's own text*, so a row built for one would turn "run this
    /// named binary, once you approve it" into "run this sentence", with no
    /// approval anywhere near it.
    ///
    /// Today no view builds that row, and until now that was the entire
    /// guarantee: a convention every call site had to remember. Refusing
    /// here instead makes it a property of the value — it declines to name a
    /// shell command whoever asks, including a caller written next year.
    var installCommand: String? {
        /// Nil, not empty. A contributed server has no install command this
        /// app may offer, because the only text it could offer is the
        /// manifest's own — and that string would be handed to `$SHELL -lic`
        /// by the button beside it. An optional makes a caller face that;
        /// an empty string lets one render a button that runs nothing.
        guard case .builtIn = origin else { return nil }
        switch command {
        case "sourcekit-lsp": return "xcode-select --install"
        case "clangd": return "xcode-select --install"
        default: return installHint
        }
    }

    var installHelper: String? {
        switch command {
        case "sourcekit-lsp": return "SourceKit-LSP ships with Xcode."
        case "clangd": return "clangd ships with Xcode Command Line Tools."
        default: return nil
        }
    }

    /// The reverse of `installCommand`, or nil when nothing sensible can be
    /// uninstalled automatically — `go install` has no inverse, and Xcode's
    /// bundled tools should not be removed.
    ///
    /// Keyed off `command`, which is the *binary*: the case that named the
    /// npm package `vscode-langservers-extracted` matched no server at all,
    /// because the three servers that package ships are three separate
    /// binaries — and each of them was left with a permanently disabled
    /// Uninstall button. Removing any one of them removes the package, and
    /// so the other two with it.
    var uninstallCommand: String? {
        guard case .builtIn = origin else { return nil }
        switch command {
        /// Only itself. It used to take `typescript` with it, which reads
        /// as tidy and removes another row's package: the native server on
        /// this same screen *is* `typescript`, so uninstalling the wrapper
        /// turned "TypeScript (native)" into "not installed" with nothing
        /// said. Each row removes what it is.
        case "typescript-language-server": return "npm rm -g typescript-language-server"
        /// The native server *is* the TypeScript package — removing it is
        /// removing TypeScript, not an editor tool that wraps it.
        case "tsc": return "npm rm -g typescript"
        /// Both halves. Settings installs them pinned together because a
        /// mismatched pair fails without either reporting it, so removing
        /// one would leave the other orphaned and out of step with the next
        /// install.
        case "vue-language-server": return "npm rm -g @vue/language-server @vue/typescript-plugin"
        case "pyright-langserver": return "npm rm -g pyright"
        case "vscode-css-language-server", "vscode-html-language-server",
             "vscode-json-language-server":
            return "npm rm -g vscode-langservers-extracted"
        case "yaml-language-server": return "npm rm -g yaml-language-server"
        case "taplo": return "brew uninstall taplo"
        case LSPServerRegistry.tailwindCommand: return "npm rm -g @tailwindcss/language-server"
        case "bash-language-server": return "npm rm -g bash-language-server"
        case "intelephense": return "npm rm -g intelephense"
        case "kotlin-language-server": return "brew uninstall kotlin-language-server"
        case "zls": return "brew uninstall zls"
        case "jdtls": return "brew uninstall jdtls"
        case "terraform-ls": return "brew uninstall hashicorp/tap/terraform-ls"
        case "marksman": return "brew uninstall marksman"
        case "ruby-lsp": return "gem uninstall ruby-lsp"
        case "rust-analyzer": return "rustup component remove rust-analyzer"
        case "sourcekit-lsp", "clangd", "gopls":
            return nil
        default: return nil
        }
    }

    /// Official project documentation, when the server has a stable public
    /// home. Kept next to the definition so Settings does not need a second
    /// table that can drift out of sync with the registry.
    var documentationURL: URL? {
        let address: String?
        switch command {
        case "typescript-language-server": address = "https://github.com/typescript-language-server/typescript-language-server"
        case "vue-language-server": address = "https://github.com/vuejs/language-tools"
        case "sourcekit-lsp": address = "https://github.com/swiftlang/sourcekit-lsp"
        case "kotlin-language-server": address = "https://github.com/fwcd/kotlin-language-server"
        case "pyright-langserver": address = "https://github.com/microsoft/pyright"
        case "rust-analyzer": address = "https://rust-analyzer.github.io"
        case "gopls": address = "https://go.dev/gopls"
        case "terraform-ls": address = "https://github.com/hashicorp/terraform-ls"
        case "zls": address = "https://github.com/zigtools/zls"
        case "vscode-json-language-server": address = "https://github.com/hrsh7th/vscode-langservers-extracted"
        case "yaml-language-server": address = "https://github.com/redhat-developer/yaml-language-server"
        case "taplo": address = "https://taplo.tamasfe.dev"
        case "bash-language-server": address = "https://github.com/bash-lsp/bash-language-server"
        case "vscode-html-language-server": address = "https://github.com/microsoft/vscode"
        case "vscode-css-language-server": address = "https://github.com/microsoft/vscode"
        case "jdtls": address = "https://github.com/eclipse-jdtls/eclipse.jdt.ls"
        case "clangd": address = "https://clangd.llvm.org"
        case "intelephense": address = "https://intelephense.com"
        case "ruby-lsp": address = "https://github.com/Shopify/ruby-lsp"
        case "marksman": address = "https://github.com/artempyanykh/marksman"
        case LSPServerRegistry.tailwindCommand:
            address = "https://github.com/tailwindlabs/tailwindcss-intellisense"
        default: address = nil
        }
        return address.flatMap(URL.init(string:))
    }
}

/// The table of servers this editor knows how to start.
///
/// Pure data and pure lookups — no filesystem, no process, no app state —
/// so a view can ask it what a language *would* need without any of that
/// having happened yet.
enum LSPServerRegistry {
    static let all: [LSPServerDefinition] = [
        LSPServerDefinition(
            languageID: "typescript",
            displayName: "TypeScript (npm)",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server"
        ),
        LSPServerDefinition(
            languageID: "typescriptreact",
            displayName: "TypeScript (npm)",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server"
        ),
        LSPServerDefinition(
            languageID: "javascript",
            displayName: "TypeScript (npm)",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server"
        ),
        LSPServerDefinition(
            languageID: "javascriptreact",
            displayName: "TypeScript (npm)",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server"
        ),
        LSPServerDefinition(
            languageID: "vue",
            displayName: "Vue Language Server",
            command: "vue-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g @vue/language-server",
            // Volar can't find TypeScript on its own the way an editor
            // that already indexed the project would; without this it
            // stays silent on every .vue file's <script> block. Version 3
            // reads the same path from `--tsdk` instead, and does not start
            // serving without it — see
            // `LSPInitializationOptions.vueTSDKArgument(tsdk:)`.
            initializationOptionsKind: .vueTypeScriptSDK
        ),
        LSPServerDefinition(
            languageID: "swift",
            displayName: "SourceKit-LSP",
            command: "sourcekit-lsp",
            arguments: [],
            installHint: "Ships with Xcode — run: xcode-select --install"
        ),
        LSPServerDefinition(
            languageID: "kotlin",
            displayName: "Kotlin Language Server",
            command: "kotlin-language-server",
            arguments: [],
            installHint: "brew install kotlin-language-server",
            // 1.3.13 bundles kotlin-compiler 2.1.0, whose IntelliJ core
            // throws `IllegalArgumentException: 25.0.3` reading the version
            // of a JDK 25 and exits before answering `initialize`. 21 is
            // what Homebrew's own launcher falls back to, and the newest
            // this was seen to work on; a newer server can raise it.
            maximumJavaFeatureVersion: 21
        ),
        LSPServerDefinition(
            languageID: "python",
            displayName: "Pyright",
            command: "pyright-langserver",
            arguments: ["--stdio"],
            installHint: "npm i -g pyright"
        ),
        LSPServerDefinition(
            languageID: "rust",
            displayName: "rust-analyzer",
            command: "rust-analyzer",
            arguments: [],
            installHint: "rustup component add rust-analyzer"
        ),
        LSPServerDefinition(
            languageID: "go",
            displayName: "gopls",
            command: "gopls",
            arguments: [],
            installHint: "go install golang.org/x/tools/gopls@latest"
        ),
        LSPServerDefinition(
            languageID: "zig",
            displayName: "Zig Language Server",
            command: "zls",
            arguments: [],
            installHint: "brew install zls"
        ),
        LSPServerDefinition(
            languageID: "json",
            displayName: "JSON Language Server",
            command: "vscode-json-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g vscode-langservers-extracted",
            // Ships a formatter and reports `documentFormattingProvider:
            // false` until a client asks for it. See `.provideFormatter`.
            initializationOptionsKind: .provideFormatter
        ),
        LSPServerDefinition(
            languageID: "yaml",
            displayName: "YAML Language Server",
            command: "yaml-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g yaml-language-server"
        ),
        LSPServerDefinition(
            languageID: "toml",
            displayName: "Taplo",
            // `lsp stdio` — a subcommand and its transport, not a flag. Taplo
            // is a TOML toolkit whose language server is one of several things
            // the binary does, so `--stdio` alone is a usage error here.
            command: "taplo",
            arguments: ["lsp", "stdio"],
            // Homebrew builds it with `features: "lsp"`, so the bottle can
            // serve; `cargo install taplo-cli` without `--features lsp` gives
            // a binary whose `lsp` subcommand does not exist.
            installHint: "brew install taplo"
        ),
        LSPServerDefinition(
            languageID: "shellscript",
            displayName: "Bash Language Server",
            command: "bash-language-server",
            arguments: ["start"],
            installHint: "npm i -g bash-language-server"
        ),
        LSPServerDefinition(
            languageID: "html",
            displayName: "HTML Language Server",
            command: "vscode-html-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g vscode-langservers-extracted",
            // Ships a formatter and reports `documentFormattingProvider:
            // false` until a client asks for it. See `.provideFormatter`.
            initializationOptionsKind: .provideFormatter
        ),
        LSPServerDefinition(
            languageID: "css",
            displayName: "CSS Language Server",
            command: "vscode-css-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g vscode-langservers-extracted",
            // Ships a formatter and reports `documentFormattingProvider:
            // false` until a client asks for it. See `.provideFormatter`.
            initializationOptionsKind: .provideFormatter
        ),
        LSPServerDefinition(
            languageID: "scss",
            displayName: "CSS Language Server",
            command: "vscode-css-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g vscode-langservers-extracted",
            // Ships a formatter and reports `documentFormattingProvider:
            // false` until a client asks for it. See `.provideFormatter`.
            initializationOptionsKind: .provideFormatter
        ),
        LSPServerDefinition(
            languageID: "less",
            displayName: "CSS Language Server",
            command: "vscode-css-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g vscode-langservers-extracted",
            // Ships a formatter and reports `documentFormattingProvider:
            // false` until a client asks for it. See `.provideFormatter`.
            initializationOptionsKind: .provideFormatter
        ),
        LSPServerDefinition(
            languageID: "java",
            displayName: "Eclipse JDT Language Server",
            command: "jdtls",
            // Eclipse's own workspace model needs a `-data` directory to
            // keep its index in; one fixed path rather than one per
            // project root, so switching projects re-imports into the same
            // workspace instead of paying a full fresh index every time.
            arguments: ["-data", NSHomeDirectory() + "/.cache/jdtls-workspace"],
            installHint: "brew install jdtls"
        ),
        LSPServerDefinition(
            languageID: "c",
            displayName: "clangd",
            command: "clangd",
            arguments: [],
            installHint: "Ships with Xcode Command Line Tools — run: xcode-select --install"
        ),
        LSPServerDefinition(
            languageID: "cpp",
            displayName: "clangd",
            command: "clangd",
            arguments: [],
            installHint: "Ships with Xcode Command Line Tools — run: xcode-select --install"
        ),
        LSPServerDefinition(
            languageID: "terraform",
            displayName: "terraform-ls",
            command: "terraform-ls",
            arguments: ["serve"],
            installHint: "brew install hashicorp/tap/terraform-ls"
        ),
        LSPServerDefinition(
            languageID: "php",
            displayName: "Intelephense",
            command: "intelephense",
            arguments: ["--stdio"],
            installHint: "npm i -g intelephense"
        ),
        LSPServerDefinition(
            languageID: "ruby",
            displayName: "Ruby LSP",
            command: "ruby-lsp",
            arguments: [],
            installHint: "gem install ruby-lsp"
        ),
        LSPServerDefinition(
            languageID: "markdown",
            displayName: "Marksman",
            command: "marksman",
            arguments: ["server"],
            installHint: "brew install marksman"
        )
    ]

    /// The servers that speak LSP without a wrapper.
    ///
    /// A table of its own rather than four more rows in `all`, because
    /// `all` holds one entry per language id — `byLanguageID` keeps the
    /// first of a duplicate and a repeated id there is normally a mistake,
    /// which `languageIDsAreUnique` is there to catch. These deliberately
    /// repeat four ids that `all` already has: they are the *other* server
    /// for those languages, chosen per project rather than per language.
    /// `distinctServers` unions both, so Settings lists the row.
    ///
    /// `byLanguageID` is built from `all` alone, so "the" server of a
    /// language is still the wrapper. Which of the two a file actually gets
    /// is not a property of the language and is not decided here — see
    /// `servers(forPath:toolchain:tailwind:)`.
    ///
    /// The hint is unpinned on purpose, the mirror of the `@6` on the wrapper:
    /// `npm i -g typescript` installs 7, which is exactly what these rows want
    /// and exactly what the wrapper cannot use.
    static let nativeServers: [LSPServerDefinition] = [
        LSPServerDefinition(
            languageID: "typescript",
            displayName: "TypeScript 7 (Go)",
            command: "tsc",
            arguments: ["--lsp", "--stdio"],
            installHint: "npm i -g typescript"
        ),
        LSPServerDefinition(
            languageID: "typescriptreact",
            displayName: "TypeScript 7 (Go)",
            command: "tsc",
            arguments: ["--lsp", "--stdio"],
            installHint: "npm i -g typescript"
        ),
        LSPServerDefinition(
            languageID: "javascript",
            displayName: "TypeScript 7 (Go)",
            command: "tsc",
            arguments: ["--lsp", "--stdio"],
            installHint: "npm i -g typescript"
        ),
        LSPServerDefinition(
            languageID: "javascriptreact",
            displayName: "TypeScript 7 (Go)",
            command: "tsc",
            arguments: ["--lsp", "--stdio"],
            installHint: "npm i -g typescript"
        )
    ]

    /// Tailwind IntelliSense, which is a *second* server for a file rather
    /// than an alternative to its first — the same relationship the Vue
    /// server has with `typescript-language-server`, and a third table for
    /// the same reason `nativeServers` is one: these ids are already in
    /// `all`, and `byLanguageID` must keep answering with the server that
    /// completes the language itself.
    ///
    /// **One entry per language id, not one server for all of them**, because
    /// `didOpen` announces `definition.languageID` and the server picks how to
    /// extract classes from it. A document arriving as anything else is a
    /// document it has no rule for. The cost is one process per language id
    /// per workspace — a repository with `.tsx` and `.vue` files open runs
    /// two — which is the same arithmetic `LSPCenter.Key` already applies to
    /// every other server.
    ///
    /// **`typescript` and `javascript` are treated differently on purpose.**
    /// JSX is a syntax error in a `.ts`, so a `class=` attribute cannot appear
    /// there and a process for it would answer nothing; `.js` files carrying
    /// JSX are what half of npm ships, so that id is in.
    ///
    /// Measured against 0.16.0: no `initializationOptions` are required, and
    /// the `workspace/configuration` requests it sends are satisfied by the
    /// nulls `LSPProcess.defaultAnswer` already replies with — it resolves
    /// the project from `rootUri` alone, including a v4 project whose theme
    /// lives in CSS.
    static let tailwindCommand = "tailwindcss-language-server"

    static let tailwindServers: [LSPServerDefinition] = [
        "html", "vue", "typescriptreact", "javascriptreact", "javascript",
    ].map { languageID in
        LSPServerDefinition(
            languageID: languageID,
            displayName: "Tailwind CSS",
            command: tailwindCommand,
            arguments: ["--stdio"],
            installHint: "npm i -g @tailwindcss/language-server"
        )
    }

    private static let tailwindByLanguageID: [String: LSPServerDefinition] = Dictionary(
        tailwindServers.map { ($0.languageID, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    /// The Tailwind server for a language, when there is one for it.
    static func tailwindServer(forLanguage languageID: String) -> LSPServerDefinition? {
        tailwindByLanguageID[languageID.lowercased()]
    }

    private static let byLanguageID: [String: LSPServerDefinition] = Dictionary(
        all.map { ($0.languageID, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    // MARK: Which servers a file gets

    /// The command of the server that speaks LSP without a wrapper.
    static let nativeTypeScriptCommand = "tsc"

    /// Every file extension `tsc --lsp --stdio` will accept.
    ///
    /// **An allowlist, and it may never become a subtraction.** Measured, one
    /// `didOpen` per process: `.ts`, `.tsx`, `.js`, `.jsx`, `.mts`, `.cts` and
    /// `.json` are served; `.vue`, `.svelte`, `.astro`, `.mdx`, `.css` and a
    /// file with no extension at all each **kill the process**:
    ///
    /// ```
    /// panic: ScriptKind must be specified when parsing source file: …/probe.vue
    /// github.com/microsoft/typescript-go/internal/parser.(*Parser).initializeState
    /// ```
    ///
    /// It does not answer empty and it does not decline the document — it
    /// dies, and every other file that server was serving dies with it. That
    /// is why "everything except `.vue`" is the wrong shape: `.vue` is only
    /// the first one anybody happened to try.
    ///
    /// **This is an upstream defect, not a design limit.** A language server
    /// is supposed to decline a document it cannot parse, the way
    /// `typescript-language-server` answers `Unexpected resource …`. If
    /// `typescript-go` fixes it, this list can grow — until then it is the
    /// contract, and `LSPServerRegistryTests` fails anyone who widens the
    /// native entry past it.
    static let nativeTypeScriptExtensions: Set<String> = [
        "ts", "tsx", "js", "jsx", "mts", "cts", "json",
    ]

    /// Whether a binary may be handed this file at all.
    ///
    /// Keyed on the **command**, and the alternative is worth writing down
    /// because it is the more obvious one: put the accepted set on
    /// `LSPServerDefinition` and let it ride along the way `origin` does.
    /// That does not work here, and the reason is what the two facts are
    /// *about*. `origin` is a fact about where a definition came from, which
    /// genuinely differs per definition. "`tsc` dies on a `.css`" is a fact
    /// about the binary, identical for every definition that names it —
    /// including the two this app never writes:
    ///
    /// - a **user override** repointing some other language's command at
    ///   `tsc`, which keeps that language's definition and therefore that
    ///   definition's (absent) field;
    /// - a **contributed manifest** declaring `command: "tsc"` with
    ///   `args: ["--lsp", "--stdio"]`, whose definition this file never
    ///   built and cannot annotate.
    ///
    /// Neither would carry a field, so a field would protect neither. A
    /// lookup by command protects both, and the usual objection to a lookup —
    /// that a call site can forget it — is answered by there being exactly
    /// one call site: `LSPCenter.resolvedPairs(forPath:)`, after the override
    /// is applied, which is the only way any definition reaches a process.
    ///
    /// The trust gate cannot cover this. It approves a *command*; it has no
    /// way to know the command panics on the file about to be opened, and a
    /// user who approved `tsc` approved a language server, not a crash.
    static func accepts(command: String, path: String) -> Bool {
        guard command == nativeTypeScriptCommand else { return true }
        return nativeTypeScriptExtensions.contains(
            (path as NSString).pathExtension.lowercased()
        )
    }

    /// Every server that should serve a file, primary first.
    ///
    /// Pure: the workspace's TypeScript arrives as a value, because deciding
    /// it means touching a disk and this type does not. See
    /// `TypeScriptToolchain.resolve(root:)`, and `LanguageResolver` for the
    /// call that joins the two.
    /// `tailwind` is required rather than defaulted, and that is the same
    /// judgement `LSPServerDefinition.origin` documents in reverse: a default
    /// here would mean a call site that forgot to resolve it silently loses
    /// the feature, and losing a feature quietly is the failure mode this
    /// whole file keeps arguing against. There is one caller.
    static func servers(
        forPath path: String,
        toolchain: TypeScriptToolchain,
        tailwind: TailwindProject
    ) -> [LSPServerDefinition] {
        guard let languageID = languageID(forPath: path) else { return [] }

        let primary = primaryServers(forLanguage: languageID, toolchain: toolchain)
        guard tailwind.isInstalled, let tailwind = tailwindServer(forLanguage: languageID) else {
            return primary
        }

        /// Last, because the order is "primary first" and everything that
        /// merges answers from several servers reads it that way — the
        /// language's own server is the one whose hover and diagnostics
        /// should win. Tailwind adds classes to a completion list; it has no
        /// opinion about the code around them.
        return primary + [tailwind]
    }

    private static func primaryServers(
        forLanguage languageID: String,
        toolchain: TypeScriptToolchain
    ) -> [LSPServerDefinition] {
        if languageID == "vue" { return vueServers(toolchain: toolchain) }

        guard let wrapper = server(forLanguage: languageID) else { return [] }
        guard wrapper.command == "typescript-language-server" else { return [wrapper] }

        /// The choice this whole file exists for, and it is a fact about the
        /// project rather than a preference: a workspace with a `tsserver.js`
        /// gets the wrapper that drives it, and a workspace without one gets
        /// the binary that needs none. Pointing the wrapper at a TypeScript 7
        /// does not degrade — it exits during `initialize`.
        switch toolchain {
        case .tsserver:
            return [wrapper]
        case .native:
            return nativeServer(forLanguage: languageID).map { [$0] } ?? [wrapper]
        }
    }

    /// A `.vue` is served by two processes, and has been since Volar 2
    /// dropped takeover mode: the Vue server for the template and the style,
    /// and `typescript-language-server` — loading `@vue/typescript-plugin` —
    /// for the `<script>` block. One server per language id is the Volar 1.x
    /// model.
    ///
    /// **The native entry is never one of them, and the reason is not that it
    /// would not help.** It is that a `.vue` handed to `tsc --lsp` panics the
    /// process — see `nativeTypeScriptExtensions`.
    ///
    /// **Both are returned even when the project cannot run the second one,
    /// and that is deliberate.** Pruning it here was the first shape of this
    /// function and it produced exactly the silence the feature exists to
    /// remove: a server that is never routed is never launched, so the
    /// sentence explaining *why* it is missing — which lives in the
    /// `initializationOptions` resolution — never runs either. The reader got
    /// a working template, an empty `<script>`, and nothing to read.
    ///
    /// So routing answers "who serves this language" and launching answers
    /// "can it actually run here". The second question has a voice; the first
    /// one does not. Nothing is spawned on the failing path — the options
    /// resolve before any process exists.
    private static func vueServers(toolchain: TypeScriptToolchain) -> [LSPServerDefinition] {
        guard let vue = server(forLanguage: "vue") else { return [] }
        return [vue, vueTypeScriptServer]
    }

    /// The TypeScript half of a `.vue`.
    ///
    /// `languageID` is **`vue`**, not `typescript`, and that is load-bearing
    /// rather than cosmetic: the plugin's `languages` array becomes tsserver's
    /// `modeIds`, which is what registers this server for `vue` at all, and
    /// the document has to arrive announced as `vue` to match it. It also
    /// keeps this process on its own `LSPCenter.Key` — same language, same
    /// root, different command — instead of colliding with the Vue server.
    ///
    /// It serves the template too, indirectly: version 3 of the Vue server
    /// asks *this* process every type-aware question it has, including the
    /// one that offers a component the file has not imported. See
    /// `LSPTSServerBridge`.
    static let vueTypeScriptServer = LSPServerDefinition(
        languageID: "vue",
        displayName: "TypeScript (npm)",
        command: "typescript-language-server",
        arguments: ["--stdio"],
        installHint: "npm i -g typescript-language-server",
        initializationOptionsKind: .vueTypeScriptPlugin
    )

    private static let nativeByLanguageID: [String: LSPServerDefinition] = Dictionary(
        nativeServers.map { ($0.languageID, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static func nativeServer(forLanguage languageID: String) -> LSPServerDefinition? {
        nativeByLanguageID[languageID]
    }

    /// The language ids share servers — four of them are the same
    /// TypeScript process — so extensions map to a language first and a
    /// server only through it. `.jsonc` and `.mjs` are here because they
    /// are what real projects contain, not because LSP names them.
    private static let languageIDByExtension: [String: String] = [
        "ts": "typescript",
        "mts": "typescript",
        "cts": "typescript",
        "tsx": "typescriptreact",
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "jsx": "javascriptreact",
        "vue": "vue",
        "swift": "swift",
        "kt": "kotlin",
        "kts": "kotlin",
        "py": "python",
        "pyi": "python",
        "rs": "rust",
        "go": "go",
        // Go module manifests use their own extensions, but are handled by
        // gopls with the same language id as Go source files.
        "zig": "zig",
        "json": "json",
        "jsonc": "json",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "toml",
        "sh": "shellscript",
        "bash": "shellscript",
        "zsh": "shellscript",
        "html": "html",
        "htm": "html",
        "css": "css",
        "scss": "scss",
        "less": "less",
        "java": "java",
        "c": "c",
        "h": "c",
        "cpp": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "hxx": "cpp",
        "tf": "terraform",
        "tfvars": "terraform",
        "php": "php",
        "rb": "ruby",
        "md": "markdown",
        "markdown": "markdown",
        "mdx": "markdown"
    ]

    /// Nil for a language nobody has taught this table about — which is the
    /// normal case for most files a terminal opens, and not an error.
    static func server(forLanguage languageID: String) -> LSPServerDefinition? {
        byLanguageID[languageID.lowercased()]
    }

    static func server(forPath path: String) -> LSPServerDefinition? {
        guard let languageID = languageID(forPath: path) else { return nil }
        return server(forLanguage: languageID)
    }

    /// Files whose *name* decides the language, because their extension
    /// does not. `.mod` and `.sum` belong to plenty of things that are not
    /// Go — a Fortran module, a checksum list — and matching on the
    /// extension started gopls for every one of them.
    ///
    /// The `rc` files are the opposite problem: they have no extension at
    /// all, so nothing here could match them but their name. Each is
    /// **allowed** to hold YAML instead of JSON, and each is called JSON
    /// anyway — the ambiguity is real and it is not evenly weighted. A JSON
    /// `.prettierrc` is what the tooling writes and what almost every
    /// project contains; a YAML one is a choice somebody made. Calling them
    /// JSON serves the common file and mis-serves the rare one visibly,
    /// with diagnostics that say the document is not JSON. Calling them
    /// YAML would mis-serve the common one, and a project that wants the
    /// other answer can spell the extension: `.prettierrc.yaml` resolves
    /// through the extension table, above, with nothing needed here.
    ///
    /// Deciding by content instead is the answer this cannot have. Both
    /// tables are consulted from a name — `CodeLanguage.resolve(fileName:)`
    /// is handed no path at all — and this type opens no files, which is
    /// the property that lets a view ask it what a language would need
    /// before anything has happened.
    ///
    /// `.npmrc` is not here, and not by oversight: it is INI.
    private static let languageIDByFileName: [String: String] = [
        "go.mod": "go",
        "go.sum": "go",
        "go.work": "go",
        ".prettierrc": "json",
        ".babelrc": "json",
        ".eslintrc": "json",
        ".jscsrc": "json",
        ".jshintrc": "json",
        ".swcrc": "json",
    ]

    static func languageID(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if let byName = languageIDByFileName[name.lowercased()] { return byName }

        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return languageIDByExtension[ext]
    }

    /// One entry per distinct binary, for a UI that lists what could be
    /// installed — listing the TypeScript server four times because four
    /// language ids point at it would be noise.
    static var distinctServers: [LSPServerDefinition] {
        var seen: Set<String> = []
        return (all + nativeServers + tailwindServers)
            .filter { seen.insert($0.command).inserted }
    }
}
