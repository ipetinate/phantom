import Foundation

/// Whether a project formats with Prettier, and which Prettier it would use.
///
/// This type answers one question — *routing*: is this a Prettier project, and
/// is this a file Prettier handles? It deliberately does **not** read the
/// configuration it finds.
///
/// Prettier resolves its own configuration when it is handed
/// `--stdin-filepath`, walking up from that path exactly as it would for a
/// file on disk, honouring `overrides`, `extends`, `.editorconfig` and
/// `.prettierignore` on the way. Half of the config formats it can be given
/// are *programs* — `.prettierrc.js`, `prettier.config.mjs`,
/// `prettier.config.ts` — which cannot be read without executing JavaScript.
/// Parsing the declarative half would therefore produce a second, partial,
/// silently-diverging notion of the user's settings, and the first bug report
/// would be "Phantom formats this file differently from `npx prettier`".
///
/// So: find out *that* Prettier owns the file, hand Prettier the path, and get
/// out of the way. Adding a YAML or JSON5 parser here is not an improvement.
struct PrettierProject: Equatable, Sendable {
    /// The nearest configuration file found on the walk, if any.
    ///
    /// Only its existence is meaningful — see the type's note. It is carried
    /// so a settings screen can show *why* Phantom thinks this is a Prettier
    /// project, and so the run can be rooted at the directory holding it.
    let configurationPath: String?

    /// The nearest `node_modules/.bin/prettier`, if any.
    let localBinaryPath: String?

    /// Where the walk stopped: the enclosing repository, or the home
    /// directory. Nil when neither was reached before the depth limit.
    let rootPath: String?

    /// True when anything at all said "this project uses Prettier".
    var isPrettierProject: Bool {
        configurationPath != nil || localBinaryPath != nil
    }

    /// The directory to run Prettier in.
    ///
    /// The config's own directory first: a `plugins` entry in a config is
    /// resolved relative to that config, and a monorepo package that formats
    /// differently from its root would otherwise be run from the wrong place.
    var workingDirectory: String? {
        if let configurationPath { return (configurationPath as NSString).deletingLastPathComponent }
        return rootPath
    }
}

extension PrettierProject {
    // MARK: The decision

    /// Every file name Prettier can infer a parser for without a plugin, as
    /// name suffixes.
    ///
    /// Generated from a real `prettier --support-info` run — Prettier 3.9.6,
    /// installed clean — and not from the docs, which list the supported
    /// *languages* and never their extensions. Prettier builds this mapping at
    /// runtime from the `linguist-languages` package, filtered and extended per
    /// language in `src/*/languages.evaluate.js`, so `--support-info` is the
    /// only place the real answer exists.
    ///
    /// **Suffixes, not extensions.** Prettier matches the lowercased base name
    /// against each entry with `endsWith`, which is the only way the compound
    /// ones can work: `.js.flow` is Flow, `.tfstate.backup` and `.json.example`
    /// are JSON, `.yaml.sed` and `.yml.mysql` are YAML, `.component.html` is
    /// Angular. Matching only the last dotted component — what this list did
    /// before — missed every one of them, and would have claimed `shader.frag`
    /// on the strength of `.start.frag`, which Prettier does not touch
    /// (measured: `--file-info shader.frag` infers nothing).
    ///
    /// Extensions Prettier supports and this list leaves out are a
    /// *conservative* failure — the file is simply not offered formatting. The
    /// opposite mistake is the expensive one, and it is not hypothetical:
    /// handed a file it has no parser for, Prettier exits **2** with
    /// `No parser could be inferred`, which is an error banner on every save of
    /// that file forever.
    ///
    /// Which is why `svelte` is **not** here. Core Prettier does not handle it
    /// — it needs `prettier-plugin-svelte` — and claiming it produced exactly
    /// that banner when tried. Formatting Svelte would mean knowing whether the
    /// project's config loads that plugin, and reading the config is the one
    /// thing this type will not do; see the note above. A Svelte project
    /// therefore gets no formatting from us rather than an error on every save.
    ///
    /// Two sets of entries from `--support-info` are deliberately absent:
    ///
    /// - `.4DForm`, `.4DProject` and `.JSON-tmLanguage`, because Prettier
    ///   lowercases the name before comparing and never lowercases these — so
    ///   Prettier itself can infer no parser for them. Measured both ways:
    ///   `x.4DForm` and `x.4dform` both infer nothing. Copying them here would
    ///   claim files Prettier then refuses, which is the error banner above.
    /// - `.inc`, which linguist calls HTML and the world uses for PHP and ASP
    ///   includes. Prettier would format one as HTML — and the HTML parser does
    ///   not refuse a PHP include, it rewrites it. This is the one place where
    ///   matching Prettier exactly is worse than declining, so it declines.
    static let supportedSuffixes: Set<String> = [
        /* Angular */ ".component.html",
        /* CSS */ ".css", ".wxss",
        /* Flow */ ".js.flow",
        /* GraphQL */ ".graphql", ".gql", ".graphqls",
        /* Handlebars */ ".handlebars", ".hbs",
        /* HTML */ ".html", ".hta", ".htm", ".html.hl", ".xht", ".xhtml",
        /* JavaScript */ ".js", "._js", ".bones", ".cjs", ".es", ".es6", ".gs",
        ".jake", ".javascript", ".jsb", ".jscad", ".jsfl", ".jslib", ".jsm",
        ".jspre", ".jss", ".mjs", ".njs", ".pac", ".sjs", ".ssjs", ".xsjs",
        ".xsjslib", ".start.frag", ".end.frag", ".wxs",
        /* JSON */ ".json", ".avsc", ".geojson", ".gltf", ".har", ".ice",
        ".json.example", ".mcmeta", ".sarif", ".slnlaunch", ".tact", ".tfstate",
        ".tfstate.backup", ".topojson", ".webapp", ".webmanifest", ".yy", ".yyp",
        /* JSON with Comments */ ".jsonc", ".code-snippets", ".code-workspace",
        ".sublime-build", ".sublime-color-scheme", ".sublime-commands",
        ".sublime-completions", ".sublime-keymap", ".sublime-macro",
        ".sublime-menu", ".sublime-mousemap", ".sublime-project",
        ".sublime-settings", ".sublime-theme", ".sublime-workspace",
        ".sublime_metrics", ".sublime_session",
        /* JSON.stringify */ ".importmap",
        /* JSON5 */ ".json5",
        /* JSX */ ".jsx",
        /* Less */ ".less",
        /* Markdown */ ".md", ".livemd", ".markdown", ".mdown", ".mdwn", ".mkd",
        ".mkdn", ".mkdown", ".ronn", ".scd", ".workbook",
        /* MDX */ ".mdx",
        /* MJML */ ".mjml",
        /* PostCSS */ ".pcss", ".postcss",
        /* SCSS */ ".scss",
        /* TSX */ ".tsx",
        /* TypeScript */ ".ts", ".cts", ".mts",
        /* Vue */ ".vue",
        /* YAML */ ".yml", ".mir", ".reek", ".rviz", ".sublime-syntax",
        ".syntax", ".yaml", ".yaml-tmlanguage", ".yaml.sed", ".yml.mysql",
    ]

    /// The whole file names Prettier recognises, lowercased.
    ///
    /// A second list because they are matched differently — whole name, not
    /// suffix — and because the ones that matter have no extension to match on:
    /// `.prettierrc` and `.stylelintrc` are YAML, `.babelrc` and `.swcrc` are
    /// JSON, `README` with nothing after it is Markdown. Prettier compares
    /// these case-insensitively, which is why they are stored lowercased and
    /// the name is lowercased before the lookup.
    ///
    /// This is also where the old rule was wrong rather than merely narrow. It
    /// declined every dotfile on the grounds that a leading dot leaves no
    /// extension behind — true of `NSString.pathExtension`, and not what
    /// Prettier does with the same name.
    static let supportedFilenames: Set<String> = [
        /* JavaScript */ "jakefile", "start.frag", "end.frag",
        /* JSON */ ".all-contributorsrc", ".arcconfig", ".auto-changelog",
        ".c8rc", ".htmlhintrc", ".imgbotconfig", ".nycrc", ".tern-config",
        ".tern-project", ".watchmanconfig", ".babelrc", ".jscsrc", ".jshintrc",
        ".jslintrc", ".swcrc",
        /* JSON.stringify */ "package.json", "package-lock.json", "composer.json",
        /* Markdown */ "contents.lr", "readme",
        /* YAML */ ".clang-format", ".clang-tidy", ".clangd", ".gemrc",
        "citation.cff", "glide.lock", "pixi.lock", ".prettierrc",
        ".stylelintrc", ".lintstagedrc",
    ]

    /// Does Prettier own this file?
    ///
    /// A pure function of three facts, so it can be reasoned about and tested
    /// without a filesystem: the project says it uses Prettier (a config, or a
    /// Prettier installed into it), and the file is one of Prettier's.
    ///
    /// Both halves are required. A config alone is enough — a project can rely
    /// on a Prettier installed globally — and an installed Prettier alone is
    /// enough, since Prettier has defaults and a project that installed it
    /// meant to use it. Neither means no formatting: running some other
    /// project's global Prettier over a repository that formats with `gofmt`,
    /// `rustfmt` or `deno fmt` would rewrite files against the house style.
    static func handles(
        fileNamed name: String,
        hasConfiguration: Bool,
        hasLocalBinary: Bool
    ) -> Bool {
        guard hasConfiguration || hasLocalBinary else { return false }
        return parserCanBeInferred(for: name)
    }

    /// Whether Prettier would infer a parser for this name, by Prettier's own
    /// rule: lowercase the base name, try the whole names, then try the
    /// suffixes.
    ///
    /// The lowercasing is Prettier's, not a convenience of ours, and it is what
    /// makes `README.MD` and `.PRETTIERRC` work — both measured against
    /// `--file-info`.
    static func parserCanBeInferred(for name: String) -> Bool {
        let base = ((name as NSString).lastPathComponent).lowercased()
        guard !base.isEmpty else { return false }
        if supportedFilenames.contains(base) { return true }
        return supportedSuffixes.contains { base.hasSuffix($0) }
    }

    /// `handles`, asked of a discovered project.
    func handles(fileNamed name: String) -> Bool {
        Self.handles(
            fileNamed: name,
            hasConfiguration: configurationPath != nil,
            hasLocalBinary: localBinaryPath != nil
        )
    }
}

extension PrettierProject {
    // MARK: The walk

    /// Config file names Prettier reads, in the order it prefers them.
    ///
    /// Order matters only for which one is *reported*; Prettier resolves the
    /// real one itself.
    static let configurationNames: [String] = [
        ".prettierrc",
        ".prettierrc.json",
        ".prettierrc.json5",
        ".prettierrc.yaml",
        ".prettierrc.yml",
        ".prettierrc.toml",
        ".prettierrc.js",
        ".prettierrc.cjs",
        ".prettierrc.mjs",
        ".prettierrc.ts",
        ".prettierrc.mts",
        ".prettierrc.cts",
        "prettier.config.js",
        "prettier.config.cjs",
        "prettier.config.mjs",
        "prettier.config.ts",
        "prettier.config.mts",
        "prettier.config.cts",
    ]

    /// Walks up from a file looking for the two things that decide the
    /// question: a Prettier config, and a Prettier installed in the project.
    ///
    /// Both are collected on one pass, and the walk continues past the first
    /// hit for the *other* one — a monorepo package holds the config while
    /// the hoisted binary lives at the repository root, and finding only the
    /// nearer of the two would make the decision depend on which came first.
    ///
    /// ## Where it stops
    ///
    /// At the enclosing repository, or at the user's home directory,
    /// whichever comes first — never at `/`. Two reasons, and the second is
    /// the one that matters:
    ///
    /// - A config outside the repository is not this project's config. Its
    ///   author did not write it for a file they have never seen.
    /// - The directories above `~` are shared, and on a work machine not
    ///   always the user's. Reading `/.prettierrc` to decide how to rewrite
    ///   someone's buffer is a decision taken by whoever can write to `/`.
    ///
    /// `.git` is tested for *existence*, not for being a directory: in a
    /// worktree or a submodule it is a file holding a `gitdir:` pointer, and
    /// those are exactly the checkouts people do parallel work in.
    ///
    /// ## Cost
    ///
    /// Per directory: at most 14 `stat` calls that miss, one `stat` for
    /// `node_modules/.bin/prettier`, one for `.git`, and — only where a
    /// `package.json` exists — one small read and parse. A file eight
    /// directories deep in a repository therefore costs on the order of a
    /// hundred `stat`s, all of them served from the kernel's cache after the
    /// first time. Cheap enough to run per save; not so cheap that it should
    /// run per keystroke.
    ///
    /// - Parameter maximumDepth: a walk that cannot run away. The path is
    ///   arbitrary user input.
    static func discover(
        forFile path: String,
        fileManager: FileManager = .default,
        homeDirectory: String? = nil,
        maximumDepth: Int = 64
    ) -> PrettierProject {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser.path
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()

        var configurationPath: String?
        var localBinaryPath: String?
        var rootPath: String?

        for _ in 0..<maximumDepth {
            /// The root itself is never inspected. Everyone's files are under
            /// it, so a config there would apply to every project at once.
            guard directory.path != "/", !directory.path.isEmpty else { break }

            if configurationPath == nil {
                configurationPath = configuration(in: directory, fileManager: fileManager)
            }
            if localBinaryPath == nil {
                localBinaryPath = localBinary(in: directory, fileManager: fileManager)
            }

            let isRepositoryRoot = fileManager.fileExists(
                atPath: directory.appendingPathComponent(".git").path
            )
            if isRepositoryRoot || directory.path == home {
                rootPath = directory.path
                break
            }

            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }

        return PrettierProject(
            configurationPath: configurationPath,
            localBinaryPath: localBinaryPath,
            rootPath: rootPath
        )
    }

    /// A Prettier config in one directory, `package.json` included.
    static func configuration(in directory: URL, fileManager: FileManager = .default) -> String? {
        for name in configurationNames {
            let candidate = directory.appendingPathComponent(name).path
            if fileManager.fileExists(atPath: candidate) { return candidate }
        }

        let packageJSON = directory.appendingPathComponent("package.json").path
        if packageDeclaresPrettier(at: packageJSON, fileManager: fileManager) { return packageJSON }

        /// `package.yaml` is the twentieth name in Prettier's own list, and it
        /// sits at the same precedence as `package.json`.
        let packageYAML = directory.appendingPathComponent("package.yaml").path
        return packageYAMLDeclaresPrettier(at: packageYAML, fileManager: fileManager)
            ? packageYAML
            : nil
    }

    /// A Prettier installed into one directory's `node_modules`.
    static func localBinary(in directory: URL, fileManager: FileManager = .default) -> String? {
        let candidate = directory
            .appendingPathComponent("node_modules/.bin/prettier")
            .path
        return fileManager.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// Whether a `package.json` carries a `"prettier"` key.
    ///
    /// The value is not inspected. It is legally an object *or* a string
    /// naming another config file, and either way the only thing being asked
    /// is whether the author declared Prettier here.
    ///
    /// A malformed `package.json` reads as "no". It is a file somebody is
    /// probably mid-edit on, and guessing at a broken one is how a formatter
    /// starts running where it was not wanted.
    static func packageDeclaresPrettier(at path: String, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        return object["prettier"] != nil
    }

    /// Whether a `package.yaml` carries a top-level `prettier` key.
    ///
    /// **A line scan, not a parser.** Foundation ships no YAML, and the whole
    /// question is whether one key exists at the top level of a manifest —
    /// which in a `package.yaml` is written in block style, one key per line at
    /// column zero. Pulling in a YAML dependency to answer that would be a
    /// larger decision than the feature deserves, and would put a parser on
    /// the path that decides whether to reformat somebody's file.
    ///
    /// The limit, stated rather than discovered later: a manifest written as a
    /// single flow mapping — `{prettier: {...}}` on one line — reads as "no".
    /// Nothing writes a package manifest that way, and the failure is the safe
    /// direction: Prettier is not claimed, so the file is left alone instead of
    /// being reformatted by something else.
    static func packageYAMLDeclaresPrettier(at path: String, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: path),
              let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        else { return false }

        return text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            declaresPrettierKey(line)
        }
    }

    /// A top-level `prettier:` key, quoted or not.
    ///
    /// Indentation is what makes it top-level, so a leading space disqualifies
    /// the line — otherwise `dependencies:` followed by an indented
    /// `prettier: ^3.6.0` would read as a config, and a dev dependency is not
    /// a declaration that this project is configured here. That is the same
    /// distinction `packageDeclaresPrettier` gets for free from JSON.
    static func declaresPrettierKey(_ line: some StringProtocol) -> Bool {
        guard let first = line.first, first != " ", first != "\t" else { return false }

        var rest = line[line.startIndex...]
        for quote in ["\"", "'"] where rest.hasPrefix(quote) {
            rest = rest.dropFirst()
            guard rest.hasPrefix("prettier" + quote) else { return false }
            rest = rest.dropFirst(("prettier" + quote).count)
            return rest.drop(while: { $0 == " " }).hasPrefix(":")
        }

        guard rest.hasPrefix("prettier") else { return false }
        return rest.dropFirst("prettier".count).drop(while: { $0 == " " }).hasPrefix(":")
    }
}
