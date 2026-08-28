import Foundation
@testable import Ghostty
import Testing

/// Deciding that a project formats with Prettier, and that a file is one of
/// Prettier's.
///
/// The decision half is a pure function of three facts and is tested as one —
/// no temporary directories, no Prettier on the machine, nothing to be flaky
/// about. The walk is tested against trees built here, because the interesting
/// cases are all about where it *stops*: a walk that runs one directory too
/// far starts formatting files using a stranger's settings.
struct PrettierProjectTests {
    // MARK: The decision

    /// The important negative. A repository that formats with `rustfmt` or
    /// `gofmt` must not have a Prettier from somewhere else rewrite its files
    /// just because one is installed on this machine.
    @Test func nothingSayingPrettierMeansNoFormatting() {
        #expect(!PrettierProject.handles(fileNamed: "main.ts", hasConfiguration: false, hasLocalBinary: false))
        #expect(!PrettierProject.handles(fileNamed: "index.css", hasConfiguration: false, hasLocalBinary: false))
    }

    /// A config with no local Prettier is a project that expects a global one.
    @Test func aConfigAloneIsEnough() {
        #expect(PrettierProject.handles(fileNamed: "main.ts", hasConfiguration: true, hasLocalBinary: false))
    }

    /// A Prettier installed into the project with no config is a project
    /// relying on Prettier's defaults, which is a supported way to use it.
    @Test func aLocalPrettierAloneIsEnough() {
        #expect(PrettierProject.handles(fileNamed: "app.vue", hasConfiguration: false, hasLocalBinary: true))
    }

    @Test func aFileTypePrettierDoesNotHandleIsDeclined() {
        #expect(!PrettierProject.handles(fileNamed: "main.rs", hasConfiguration: true, hasLocalBinary: true))
        #expect(!PrettierProject.handles(fileNamed: "App.swift", hasConfiguration: true, hasLocalBinary: true))
        #expect(!PrettierProject.handles(fileNamed: "main.py", hasConfiguration: true, hasLocalBinary: true))
    }

    /// A name with nothing after the dot is not a name Prettier knows, and
    /// most files with no extension at all are nobody's to format.
    @Test func aFileWithNoRecognisedNameIsDeclined() {
        #expect(!PrettierProject.handles(fileNamed: "Makefile", hasConfiguration: true, hasLocalBinary: true))
        #expect(!PrettierProject.handles(fileNamed: "LICENSE", hasConfiguration: true, hasLocalBinary: true))
        #expect(!PrettierProject.handles(fileNamed: "Dockerfile", hasConfiguration: true, hasLocalBinary: true))
    }

    /// The exceptions to the line above, and they are Prettier's, not ours:
    /// `README` with nothing after it is Markdown, and `Jakefile` is
    /// JavaScript. Both measured with `--file-info`.
    @Test func theExtensionlessNamesPrettierKnowsAreHandled() {
        for name in ["README", "readme", "Jakefile", "contents.lr"] {
            #expect(
                PrettierProject.handles(fileNamed: name, hasConfiguration: true, hasLocalBinary: false),
                "\(name)")
        }
    }

    /// The rule that was wrong rather than merely narrow. A leading dot leaves
    /// `NSString.pathExtension` empty, so every dotfile was declined — and
    /// Prettier formats a good many of them: `.prettierrc` and `.stylelintrc`
    /// as YAML, `.babelrc` and `.swcrc` as JSON.
    @Test func theDotfilesPrettierKnowsAreHandled() {
        for name in [".prettierrc", ".PRETTIERRC", ".stylelintrc", ".lintstagedrc",
                     ".babelrc", ".swcrc", ".nycrc", ".clang-format", ".gemrc"] {
            #expect(
                PrettierProject.handles(fileNamed: name, hasConfiguration: true, hasLocalBinary: false),
                "\(name)")
        }
    }

    /// The dotfiles it does not know stay declined, which is most of them.
    @Test func anUnknownDotfileIsStillDeclined() {
        #expect(!PrettierProject.handles(fileNamed: ".gitignore", hasConfiguration: true, hasLocalBinary: true))
        #expect(!PrettierProject.handles(fileNamed: ".env", hasConfiguration: true, hasLocalBinary: true))
        #expect(!PrettierProject.handles(fileNamed: ".zshrc", hasConfiguration: true, hasLocalBinary: true))
    }

    /// Prettier lowercases the name before it compares, so the case of what
    /// the reader typed never decides this.
    @Test func theNameMatchIsCaseInsensitive() {
        #expect(PrettierProject.handles(fileNamed: "Component.TSX", hasConfiguration: true, hasLocalBinary: false))
        #expect(PrettierProject.handles(fileNamed: "README.MD", hasConfiguration: true, hasLocalBinary: false))
        #expect(PrettierProject.handles(fileNamed: "CITATION.cff", hasConfiguration: true, hasLocalBinary: false))
    }

    /// `component.spec.ts` is TypeScript, not a `.spec.ts` language.
    @Test func anUnknownCompoundNameFallsBackToItsLastExtension() {
        #expect(PrettierProject.handles(fileNamed: "component.spec.ts", hasConfiguration: true, hasLocalBinary: false))
    }

    /// The compound names that are their own language, and the reason the
    /// match is on suffixes at all: not one of these can be answered by
    /// looking at the last dotted component. `.flow`, `.backup`, `.example`,
    /// `.sed` and `.mysql` are not languages.
    @Test func theCompoundSuffixesThatAreTheirOwnLanguageAreHandled() {
        for name in ["types.js.flow", "main.tfstate.backup", "config.json.example",
                     "rules.yaml.sed", "schema.yml.mysql", "page.component.html",
                     "theme.html.hl"] {
            #expect(
                PrettierProject.handles(fileNamed: name, hasConfiguration: true, hasLocalBinary: false),
                "\(name)")
        }
    }

    /// Suffix matching is more precise than the last extension, not less.
    /// Prettier knows `.start.frag` and `.end.frag`; a GLSL fragment shader is
    /// neither, and `--file-info shader.frag` infers nothing.
    @Test func aSuffixDoesNotClaimTheExtensionItEndsWith() {
        #expect(PrettierProject.handles(fileNamed: "app.start.frag", hasConfiguration: true, hasLocalBinary: false))
        #expect(!PrettierProject.handles(fileNamed: "shader.frag", hasConfiguration: true, hasLocalBinary: false))
    }

    /// The module variants and aliases are the ones a hand-written list
    /// forgets, and forgetting one means that file silently never formats.
    /// Every name here was confirmed against a `prettier --support-info` run.
    @Test func theModuleAndAliasExtensionsAreAllCovered() {
        for name in ["a.mjs", "a.cjs", "a.mts", "a.cts", "a.json5", "a.jsonc", "a.gql",
                     "a.mdx", "a.markdown", "a.htm", "a.graphqls", "a.pcss", "a.hbs",
                     "a.geojson", "a.webmanifest", "phantom.code-workspace"] {
            #expect(PrettierProject.handles(fileNamed: name, hasConfiguration: true, hasLocalBinary: false), "\(name)")
        }
    }

    /// The rest of what Prettier answers for, by language, so a file type
    /// dropping out of the list is a failing test rather than a save that
    /// quietly stops formatting.
    @Test func everyLanguagePrettierShipsAParserForIsCovered() {
        for name in ["a.css", "a.wxss", "a.scss", "a.less", "a.postcss",
                     "a.html", "a.htm", "a.xht", "a.xhtml", "a.hta",
                     "a.js", "a.es6", "a.jsx", "a.wxs", "a.pac",
                     "a.ts", "a.tsx", "a.vue", "a.mjml",
                     "a.json", "a.har", "a.avsc", "a.gltf", "a.sarif",
                     "a.topojson", "a.webapp", "a.yy", "a.yyp", "a.importmap",
                     "a.sublime-project", "a.sublime_session", "a.code-snippets",
                     "a.md", "a.mdown", "a.mdwn", "a.mkd", "a.mkdn", "a.mkdown",
                     "a.livemd", "a.ronn", "a.workbook", "a.mdx",
                     "a.yaml", "a.yml", "a.mir", "a.reek", "a.rviz",
                     "a.sublime-syntax", "a.yaml-tmlanguage",
                     "a.graphql", "a.handlebars"] {
            #expect(
                PrettierProject.handles(fileNamed: name, hasConfiguration: true, hasLocalBinary: false),
                "\(name)")
        }
    }

    /// `--support-info` lists these three, and Prettier can never infer a
    /// parser for any of them: it lowercases the name and compares the
    /// extensions as written. Measured both ways — `x.4DForm` and `x.4dform`
    /// both infer nothing — so copying them here would claim files Prettier
    /// then refuses, which is an error banner on every save.
    @Test func theMixedCaseEntriesPrettierCanNeverMatchAreNotClaimed() {
        for name in ["form.4DForm", "form.4dform", "a.4DProject", "a.JSON-tmLanguage",
                     "a.json-tmlanguage"] {
            #expect(
                !PrettierProject.handles(fileNamed: name, hasConfiguration: true, hasLocalBinary: true),
                "\(name)")
        }
    }

    /// The one place where matching Prettier exactly is worse than declining.
    /// linguist calls `.inc` HTML and the world uses it for PHP and ASP
    /// includes — and the HTML parser does not refuse a PHP include, it
    /// rewrites it.
    @Test func incIsDeclinedEvenThoughPrettierWouldFormatIt() {
        #expect(!PrettierProject.handles(fileNamed: "header.inc", hasConfiguration: true, hasLocalBinary: true))
    }

    /// Svelte needs `prettier-plugin-svelte`, and core Prettier handed a
    /// `.svelte` file exits 2 with `No parser could be inferred` — measured, at
    /// 3.9.6. Claiming it would put an error banner on every save of that file.
    /// Whether the project loads the plugin is only knowable by reading its
    /// config, which is the one thing `PrettierProject` will not do.
    @Test func svelteIsDeclinedBecauseItNeedsAPlugin() {
        #expect(!PrettierProject.handles(fileNamed: "App.svelte", hasConfiguration: true, hasLocalBinary: true))
    }

    // MARK: The walk

    @Test func aConfigAtTheRepositoryRootIsFound() throws {
        let root = try makeRoot()
        try makeRepository(at: root)
        _ = try write("{}", to: root.appendingPathComponent(".prettierrc"))
        let file = try makeFile(at: root.appendingPathComponent("src/main.ts"))

        let project = PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome)
        #expect(project.configurationPath == root.appendingPathComponent(".prettierrc").path)
        #expect(project.rootPath == root.path)
        #expect(project.isPrettierProject)
        #expect(project.handles(fileNamed: "main.ts"))
    }

    /// The repository root is *inspected* and then stopped at, not stopped at
    /// before being read — an off-by-one that would miss the config almost
    /// every real project has.
    @Test func aLocalPrettierAtTheRepositoryRootIsFound() throws {
        let root = try makeRoot()
        try makeRepository(at: root)
        let binary = try write("#!/bin/sh\n", to: root.appendingPathComponent("node_modules/.bin/prettier"), executable: true)
        let file = try makeFile(at: root.appendingPathComponent("src/main.ts"))

        let project = PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome)
        #expect(project.localBinaryPath == binary.path)
        #expect(project.configurationPath == nil)
        #expect(project.isPrettierProject)
    }

    /// A `node_modules/.bin/prettier` that is not executable is a broken or
    /// half-installed tree, not a Prettier.
    @Test func aNonExecutablePrettierIsNotABinary() throws {
        let root = try makeRoot()
        try makeRepository(at: root)
        _ = try write("", to: root.appendingPathComponent("node_modules/.bin/prettier"))
        let file = try makeFile(at: root.appendingPathComponent("src/main.ts"))

        #expect(PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome).localBinaryPath == nil)
    }

    @Test func aPackageJsonWithAPrettierKeyIsAConfig() throws {
        let root = try makeRoot()
        try makeRepository(at: root)
        let package = try write(#"{"name":"x","prettier":{"semi":false}}"#, to: root.appendingPathComponent("package.json"))
        let file = try makeFile(at: root.appendingPathComponent("index.js"))

        #expect(PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome).configurationPath == package.path)
    }

    /// The value is legally a string naming another file, and that counts too.
    @Test func aPackageJsonPointingAtAnotherFileIsAConfig() throws {
        let root = try makeRoot()
        try makeRepository(at: root)
        _ = try write(#"{"prettier":"./my-config.json"}"#, to: root.appendingPathComponent("package.json"))
        let file = try makeFile(at: root.appendingPathComponent("index.js"))

        #expect(PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome).isPrettierProject)
    }

    /// Nearly every JavaScript project has a `package.json`. Treating its mere
    /// presence as "uses Prettier" would format every Node repository on the
    /// machine.
    @Test func aPackageJsonWithoutAPrettierKeyIsNotAConfig() throws {
        let root = try makeRoot()
        try makeRepository(at: root)
        _ = try write(#"{"name":"x","devDependencies":{"eslint":"^9"}}"#, to: root.appendingPathComponent("package.json"))
        let file = try makeFile(at: root.appendingPathComponent("index.js"))

        let project = PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome)
        #expect(project.configurationPath == nil)
        #expect(!project.isPrettierProject)
    }

    /// A file somebody is mid-edit on. Guessing at a broken one is how a
    /// formatter starts running where it was not wanted.
    @Test func aMalformedPackageJsonIsNotAConfig() throws {
        let root = try makeRoot()
        try makeRepository(at: root)
        _ = try write(#"{"prettier": {"#, to: root.appendingPathComponent("package.json"))
        let file = try makeFile(at: root.appendingPathComponent("index.js"))

        #expect(!PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome).isPrettierProject)
    }

    /// The monorepo shape: the package declares the config, the root holds the
    /// hoisted binary. Stopping at whichever came first would report only one
    /// of them, and which one would depend on the layout.
    @Test func theConfigAndTheBinaryAreCollectedOnOnePass() throws {
        let root = try makeRoot()
        try makeRepository(at: root)
        let binary = try write("#!/bin/sh\n", to: root.appendingPathComponent("node_modules/.bin/prettier"), executable: true)
        let package = root.appendingPathComponent("packages/app")
        let config = try write("{}", to: package.appendingPathComponent(".prettierrc.json"))
        let file = try makeFile(at: package.appendingPathComponent("src/main.ts"))

        let project = PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome)
        #expect(project.configurationPath == config.path)
        #expect(project.localBinaryPath == binary.path)
        #expect(project.rootPath == root.path)
    }

    /// The nearer config is the one that describes this file.
    @Test func theNearestConfigWins() throws {
        let root = try makeRoot()
        try makeRepository(at: root)
        _ = try write("{}", to: root.appendingPathComponent(".prettierrc"))
        let package = root.appendingPathComponent("packages/app")
        let nearer = try write("{}", to: package.appendingPathComponent(".prettierrc"))
        let file = try makeFile(at: package.appendingPathComponent("main.ts"))

        #expect(PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome).configurationPath == nearer.path)
    }

    /// A config outside the repository was not written for a file its author
    /// has never seen.
    @Test func theWalkStopsAtTheRepositoryRoot() throws {
        let outer = try makeRoot()
        _ = try write("{}", to: outer.appendingPathComponent(".prettierrc"))
        let repository = outer.appendingPathComponent("repo")
        try makeRepository(at: repository)
        let file = try makeFile(at: repository.appendingPathComponent("src/main.ts"))

        let project = PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome)
        #expect(project.configurationPath == nil)
        #expect(project.rootPath == repository.path)
    }

    /// `.git` is a *file* in a worktree or a submodule — the checkouts people
    /// do parallel work in. Requiring a directory would walk straight past
    /// them into whatever is above.
    @Test func aWorktreeWhoseGitIsAFileStillStopsTheWalk() throws {
        let outer = try makeRoot()
        _ = try write("{}", to: outer.appendingPathComponent(".prettierrc"))
        let worktree = outer.appendingPathComponent("wt")
        _ = try write("gitdir: /somewhere/.git/worktrees/wt\n", to: worktree.appendingPathComponent(".git"))
        let file = try makeFile(at: worktree.appendingPathComponent("src/main.ts"))

        let project = PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome)
        #expect(project.configurationPath == nil)
        #expect(project.rootPath == worktree.path)
    }

    /// Outside a repository the walk still has to stop somewhere, and the
    /// directories above `~` are shared — on a work machine, not always the
    /// user's. A config up there would decide how to rewrite their buffer.
    @Test func theWalkStopsAtHome() throws {
        let outer = try makeRoot()
        _ = try write("{}", to: outer.appendingPathComponent(".prettierrc"))
        let home = outer.appendingPathComponent("home")
        let file = try makeFile(at: home.appendingPathComponent("scratch/main.ts"))

        let project = PrettierProject.discover(forFile: file.path, homeDirectory: home.path)
        #expect(project.configurationPath == nil)
        #expect(project.rootPath == home.path)
    }

    /// Home is inspected before it stops the walk, same as a repository root.
    @Test func aConfigInHomeItselfIsFound() throws {
        let home = try makeRoot()
        let config = try write("{}", to: home.appendingPathComponent(".prettierrc"))
        let file = try makeFile(at: home.appendingPathComponent("scratch/main.ts"))

        #expect(PrettierProject.discover(forFile: file.path, homeDirectory: home.path).configurationPath == config.path)
    }

    /// Neither boundary reachable: the walk still terminates, and reports that
    /// it never found a root rather than pretending `/` was one.
    @Test func aWalkWithNoBoundaryStillTerminates() throws {
        let root = try makeRoot()
        let file = try makeFile(at: root.appendingPathComponent("a/b/main.ts"))

        let project = PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome)
        #expect(project.rootPath == nil)
        #expect(!project.isPrettierProject)
    }

    /// The path is arbitrary user input, so the walk is bounded independently
    /// of what it finds.
    @Test func theDepthLimitStopsTheWalk() throws {
        let root = try makeRoot()
        try makeRepository(at: root)
        _ = try write("{}", to: root.appendingPathComponent(".prettierrc"))
        let file = try makeFile(at: root.appendingPathComponent("a/b/c/main.ts"))

        let shallow = PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome, maximumDepth: 2)
        #expect(shallow.configurationPath == nil)
        #expect(shallow.rootPath == nil)

        let full = PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome)
        #expect(full.configurationPath != nil)
    }

    /// Where the run happens: beside the config, so that a `plugins` entry
    /// resolves relative to the config that named it.
    @Test func theWorkingDirectoryIsTheConfigsOwn() throws {
        let root = try makeRoot()
        try makeRepository(at: root)
        let package = root.appendingPathComponent("packages/app")
        _ = try write("{}", to: package.appendingPathComponent(".prettierrc"))
        let file = try makeFile(at: package.appendingPathComponent("main.ts"))

        #expect(PrettierProject.discover(forFile: file.path, homeDirectory: unreachableHome).workingDirectory == package.path)
    }

    // MARK: Building trees

    /// A home that no temporary tree is ever under, so the tests that are not
    /// about the home boundary are not accidentally about it.
    private var unreachableHome: String { "/nonexistent-home-\(UUID().uuidString)" }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-prettier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRepository(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    private func makeFile(at url: URL) throws -> URL {
        try write("const a = 1;\n", to: url)
    }

    @discardableResult
    private func write(_ contents: String, to url: URL, executable: Bool = false) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }
}

/// `package.yaml`, the twentieth name in Prettier's own list.
///
/// It was the one this app did not have. Checked against the official list at
/// prettier.io/docs/configuration, which puts it at the same precedence as
/// `package.json` — both are "the `prettier` key in a package manifest".
struct PrettierPackageYAMLTests {
    private func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prettier-yaml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ text: String, named name: String, in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @Test func aTopLevelPrettierKeyDeclaresTheProject() throws {
        try inTemporaryDirectory { root in
            let manifest = try write(
                "name: x\nprettier:\n  semi: false\n",
                named: "package.yaml",
                in: root)

            #expect(PrettierProject.configuration(in: root) == manifest)
        }
    }

    /// The value may be a string naming another file, exactly as in
    /// `package.json`. What is being asked is whether Prettier was declared.
    @Test func theValueIsNotInspected() throws {
        try inTemporaryDirectory { root in
            _ = try write("prettier: ./my-config.json\n", named: "package.yaml", in: root)
            #expect(PrettierProject.configuration(in: root) != nil)
        }
    }

    /// The distinction JSON gives for free: a dev dependency is indented under
    /// another key, and it is not a declaration that this project is
    /// configured here. Reading it as one would reformat files in a repo that
    /// merely has Prettier in its lockfile.
    @Test func adependencyIsNotADeclaration() throws {
        try inTemporaryDirectory { root in
            _ = try write(
                "name: x\ndevDependencies:\n  prettier: ^3.6.0\n  eslint: ^9\n",
                named: "package.yaml",
                in: root)

            #expect(PrettierProject.configuration(in: root) == nil)
        }
    }

    @Test(arguments: [
        "prettier:",
        "prettier: {}",
        "prettier :",
        "\"prettier\":",
        "'prettier':",
    ])
    func theShapesThatCount(line: String) {
        #expect(PrettierProject.declaresPrettierKey(line), "\(line)")
    }

    @Test(arguments: [
        "  prettier:",
        "\tprettier:",
        "prettierrc:",
        "prettier",
        "my-prettier:",
        "# prettier:",
    ])
    func theShapesThatDoNot(line: String) {
        #expect(!PrettierProject.declaresPrettierKey(line), "\(line)")
    }

    /// `package.json` still wins when both are present, which is the order the
    /// documentation lists them in.
    @Test func packageJSONComesFirst() throws {
        try inTemporaryDirectory { root in
            let json = try write(#"{"prettier":{}}"#, named: "package.json", in: root)
            _ = try write("prettier:\n", named: "package.yaml", in: root)

            #expect(PrettierProject.configuration(in: root) == json)
        }
    }

    /// Every name the documentation lists is one this app looks for. The count
    /// is spelled out so adding a name to the table without adding it here
    /// fails rather than passing quietly.
    @Test func theWholeDocumentedListIsCovered() {
        let dedicated = Set(PrettierProject.configurationNames)

        for name in [
            ".prettierrc",
            ".prettierrc.json", ".prettierrc.yml", ".prettierrc.yaml", ".prettierrc.json5",
            ".prettierrc.js", "prettier.config.js", ".prettierrc.ts", "prettier.config.ts",
            ".prettierrc.mjs", "prettier.config.mjs", ".prettierrc.mts", "prettier.config.mts",
            ".prettierrc.cjs", "prettier.config.cjs", ".prettierrc.cts", "prettier.config.cts",
            ".prettierrc.toml",
        ] {
            #expect(dedicated.contains(name), "\(name) is not looked for")
        }

        /// The two manifests are not in that list because their mere presence
        /// means nothing — the `prettier` key is what counts.
        #expect(dedicated.count == 18)
        #expect(!dedicated.contains("package.json"))
        #expect(!dedicated.contains("package.yaml"))
    }
}
