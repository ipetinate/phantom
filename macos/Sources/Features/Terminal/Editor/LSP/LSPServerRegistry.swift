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

    /// CSS and its preprocessors.
    case styles

    /// JSON, YAML and other structured data.
    case data

    /// Infrastructure-as-code.
    case infrastructure

    var id: String { rawValue }

    /// The section header shown in Settings. "Script" and "Compiled" are the
    /// first two so the two big families are visible without scrolling.
    var title: String {
        switch self {
        case .script: return "Script"
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
        case "typescript-language-server", "tsc", "vue-language-server",
             "pyright-langserver", "bash-language-server",
             "intelephense", "ruby-lsp":
            return .script
        case "sourcekit-lsp", "kotlin-language-server", "rust-analyzer",
             "gopls", "zls", "jdtls", "clangd":
            return .compiled
        case "vscode-html-language-server", "marksman":
            return .markup
        case "vscode-css-language-server":
            return .styles
        case "vscode-json-language-server", "yaml-language-server":
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
        case "typescript-language-server": return "npm rm -g typescript-language-server typescript"
        /// The native server *is* the TypeScript package — removing it is
        /// removing TypeScript, not an editor tool that wraps it.
        case "tsc": return "npm rm -g typescript"
        case "vue-language-server": return "npm rm -g @vue/language-server"
        case "pyright-langserver": return "npm rm -g pyright"
        case "vscode-css-language-server", "vscode-html-language-server",
             "vscode-json-language-server":
            return "npm rm -g vscode-langservers-extracted"
        case "yaml-language-server": return "npm rm -g yaml-language-server"
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
        case "bash-language-server": address = "https://github.com/bash-lsp/bash-language-server"
        case "vscode-html-language-server": address = "https://github.com/microsoft/vscode"
        case "vscode-css-language-server": address = "https://github.com/microsoft/vscode"
        case "jdtls": address = "https://github.com/eclipse-jdtls/eclipse.jdt.ls"
        case "clangd": address = "https://clangd.llvm.org"
        case "intelephense": address = "https://intelephense.com"
        case "ruby-lsp": address = "https://github.com/Shopify/ruby-lsp"
        case "marksman": address = "https://github.com/artempyanykh/marksman"
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
            displayName: "TypeScript Language Server",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server typescript@6"
        ),
        LSPServerDefinition(
            languageID: "typescriptreact",
            displayName: "TypeScript Language Server",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server typescript@6"
        ),
        LSPServerDefinition(
            languageID: "javascript",
            displayName: "TypeScript Language Server",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server typescript@6"
        ),
        LSPServerDefinition(
            languageID: "javascriptreact",
            displayName: "TypeScript Language Server",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server typescript@6"
        ),
        LSPServerDefinition(
            languageID: "vue",
            displayName: "Vue Language Server",
            command: "vue-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g @vue/language-server",
            // Volar can't find TypeScript on its own the way an editor
            // that already indexed the project would; without this it
            // stays silent on every .vue file's <script> block.
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
            installHint: "npm i -g vscode-langservers-extracted"
        ),
        LSPServerDefinition(
            languageID: "yaml",
            displayName: "YAML Language Server",
            command: "yaml-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g yaml-language-server"
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
            installHint: "npm i -g vscode-langservers-extracted"
        ),
        LSPServerDefinition(
            languageID: "css",
            displayName: "CSS Language Server",
            command: "vscode-css-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g vscode-langservers-extracted"
        ),
        LSPServerDefinition(
            languageID: "scss",
            displayName: "CSS Language Server",
            command: "vscode-css-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g vscode-langservers-extracted"
        ),
        LSPServerDefinition(
            languageID: "less",
            displayName: "CSS Language Server",
            command: "vscode-css-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g vscode-langservers-extracted"
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
    /// `servers(forPath:toolchain:)`.
    ///
    /// The hint is unpinned on purpose, the mirror of the `@6` on the wrapper:
    /// `npm i -g typescript` installs 7, which is exactly what these rows want
    /// and exactly what the wrapper cannot use.
    static let nativeServers: [LSPServerDefinition] = [
        LSPServerDefinition(
            languageID: "typescript",
            displayName: "TypeScript (native)",
            command: "tsc",
            arguments: ["--lsp", "--stdio"],
            installHint: "npm i -g typescript"
        ),
        LSPServerDefinition(
            languageID: "typescriptreact",
            displayName: "TypeScript (native)",
            command: "tsc",
            arguments: ["--lsp", "--stdio"],
            installHint: "npm i -g typescript"
        ),
        LSPServerDefinition(
            languageID: "javascript",
            displayName: "TypeScript (native)",
            command: "tsc",
            arguments: ["--lsp", "--stdio"],
            installHint: "npm i -g typescript"
        ),
        LSPServerDefinition(
            languageID: "javascriptreact",
            displayName: "TypeScript (native)",
            command: "tsc",
            arguments: ["--lsp", "--stdio"],
            installHint: "npm i -g typescript"
        )
    ]

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
    static func servers(
        forPath path: String,
        toolchain: TypeScriptToolchain
    ) -> [LSPServerDefinition] {
        guard let languageID = languageID(forPath: path) else { return [] }

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
    /// process — see `nativeTypeScriptExtensions`. So a project whose
    /// TypeScript is 7 gets the template half and no script half at all, and
    /// that has to be *said* rather than left as silence: the answer is "Vue
    /// needs TypeScript 6.x in this project", not an empty completion list.
    private static func vueServers(toolchain: TypeScriptToolchain) -> [LSPServerDefinition] {
        guard let vue = server(forLanguage: "vue") else { return [] }
        guard case .tsserver = toolchain else { return [vue] }
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
    static let vueTypeScriptServer = LSPServerDefinition(
        languageID: "vue",
        displayName: "TypeScript Language Server",
        command: "typescript-language-server",
        arguments: ["--stdio"],
        installHint: "npm i -g typescript-language-server typescript@6",
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
    private static let languageIDByFileName: [String: String] = [
        "go.mod": "go",
        "go.sum": "go",
        "go.work": "go",
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
        return (all + nativeServers).filter { seen.insert($0.command).inserted }
    }
}
