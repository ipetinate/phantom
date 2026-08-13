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

    var id: String { languageID }

    /// Which section of the Settings list this server belongs to. Keyed off
    /// the command so shared binaries (one server, four language ids) land
    /// in one place and can't disagree about it.
    var category: LSPServerCategory {
        switch command {
        case "typescript-language-server", "vue-language-server",
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
    var installCommand: String {
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
        switch command {
        case "typescript-language-server": return "npm rm -g typescript-language-server typescript"
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
            installHint: "npm i -g typescript-language-server typescript"
        ),
        LSPServerDefinition(
            languageID: "typescriptreact",
            displayName: "TypeScript Language Server",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server typescript"
        ),
        LSPServerDefinition(
            languageID: "javascript",
            displayName: "TypeScript Language Server",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server typescript"
        ),
        LSPServerDefinition(
            languageID: "javascriptreact",
            displayName: "TypeScript Language Server",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server typescript"
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
            installHint: "brew install kotlin-language-server"
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

    private static let byLanguageID: [String: LSPServerDefinition] = Dictionary(
        all.map { ($0.languageID, $0) },
        uniquingKeysWith: { first, _ in first }
    )

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
        "mod": "go",
        "sum": "go",
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

    static func languageID(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return languageIDByExtension[ext]
    }

    /// One entry per distinct binary, for a UI that lists what could be
    /// installed — listing the TypeScript server four times because four
    /// language ids point at it would be noise.
    static var distinctServers: [LSPServerDefinition] {
        var seen: Set<String> = []
        return all.filter { seen.insert($0.command).inserted }
    }
}
