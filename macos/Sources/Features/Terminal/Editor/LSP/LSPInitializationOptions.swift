import Foundation

/// How to resolve `initializationOptions` for a language, when a user
/// override doesn't already supply one.
///
/// `LSPServerDefinition` stays a plain, `Hashable` value — a closure there
/// would give every definition its own identity and break the equality
/// `LSPServerRegistry.distinctServers`'s dedup relies on. A tag plus a
/// resolver that switches on it keeps the data pure and the resolution
/// (which touches the filesystem, and for one case a subprocess) in one
/// place that can be tested on its own.
enum LSPInitializationOptionsKind: Hashable, Sendable {
    case none

    /// Volar has no way to find TypeScript itself the way an editor that
    /// already indexed the project would — without this, it stays silent
    /// on every `.vue` file's `<script>` block rather than reporting an
    /// error.
    case vueTypeScriptSDK

    /// The formatter the `vscode-langservers-extracted` servers keep switched
    /// off until a client asks for it.
    ///
    /// JSON, HTML and CSS all ship a formatter and all answer `initialize`
    /// with `documentFormattingProvider: false` without this — measured, by
    /// starting each of the three and reading the capability back. VS Code
    /// sends it because its own settings hold `json.format.enable`; a client
    /// that sends nothing gets a server that can format and says it cannot.
    case provideFormatter

    /// `typescript-language-server` serving the `<script>` half of a `.vue`.
    ///
    /// Two options, and neither is optional. `tsserver.path` is required or
    /// `initialize` answers "Could not find a valid TypeScript installation"
    /// and the process exits. `plugins` is what loads
    /// `@vue/typescript-plugin`, and its `languages` array becomes tsserver's
    /// `modeIds` — which is the thing that registers the server for `vue` at
    /// all. Without it the server refuses the document outright
    /// (`Unexpected resource …/x.vue`); with it, measured, the same file
    /// completes from inside `<script setup>`.
    case vueTypeScriptPlugin
}

enum LSPInitializationOptions {
    /// What turns the formatter on in the three `vscode-langservers-extracted`
    /// servers. One flag, spelled once, because the three read the same name.
    static let provideFormatterValue: LSPValue = ["provideFormatter": .bool(true)]

    /// The concrete alternative to the silence this whole feature exists to
    /// replace: shown when neither a project-local nor a global TypeScript
    /// can be found.
    static let missingTypeScriptMessage = """
    Volar needs TypeScript to check .vue files, and none was found in this \
    project or globally. Install it with "npm i -D typescript" in the \
    project, or "npm i -g typescript".
    """

    /// Where Volar should look for TypeScript: the project's own copy
    /// first, so a workspace pinning a version is checked against that
    /// version rather than whatever else happens to be on the machine.
    ///
    /// The global lookup shells out to `npm`, so this belongs off the main
    /// actor — see the call in `LSPCenter.server(for:)`.
    static func vueTypeScriptSDK(
        root: String,
        searchPath: String,
        fileManager: FileManager = .default
    ) -> LSPOutcome<String> {
        let local = (root as NSString).appendingPathComponent("node_modules/typescript/lib")
        if fileManager.fileExists(atPath: local) { return .success(local) }

        if let global = globalTypeScriptLib(searchPath: searchPath, fileManager: fileManager) {
            return .success(global)
        }
        return .failure(missingTypeScriptMessage)
    }

    /// `npm root -g` rather than guessing at Homebrew/nvm/volta layouts:
    /// npm already knows exactly where it put things, and a guess would be
    /// wrong for exactly the setups a guess is hardest to get right for.
    private static func globalTypeScriptLib(searchPath: String, fileManager: FileManager) -> String? {
        guard let npm = LSPProcess.locate("npm", searchPath: searchPath) else { return nil }
        guard let output = ShellCommand.run(npm, ["root", "-g"], timeout: 5) else { return nil }

        let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }

        let candidate = (root as NSString).appendingPathComponent("typescript/lib")
        return fileManager.fileExists(atPath: candidate) ? candidate : nil
    }

    /// The file every Vue server loads out of a `tsdk`, whichever way it was
    /// told where the directory is.
    static let tsdkEntryPoint = "typescript.js"

    /// The reason a directory that exists is still not a usable `tsdk`.
    ///
    /// Names TypeScript 7 because that is what it is, on every machine this
    /// fires on today: `npm i -g typescript` installs the native rewrite,
    /// whose `lib` holds `tsc.js` and a version file and nothing a language
    /// server can load. See `TypeScriptToolchain`.
    static let unloadableTypeScriptMessage = """
    The TypeScript found for this project has no library for a language \
    server to load — TypeScript 7 is the native rewrite and ships none. \
    Install one the Vue server can use with "npm i -D typescript@6" in the \
    project.
    """

    /// The `tsdk` a Vue server can actually load, or the reason there is
    /// none.
    ///
    /// The extra check exists because the path became a **launch argument**.
    /// A directory that is there but empty of `typescript.js` used to make
    /// the server report its own failure during `initialize`; version 3
    /// resolves the file while it is still starting, so the same directory
    /// now kills the process before it says anything at all. Answering here
    /// keeps the sentence the reader needs.
    static func vueLoadableTypeScriptSDK(
        root: String,
        searchPath: String,
        fileManager: FileManager = .default
    ) -> LSPOutcome<String> {
        switch vueTypeScriptSDK(root: root, searchPath: searchPath, fileManager: fileManager) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let tsdk):
            let entry = (tsdk as NSString).appendingPathComponent(tsdkEntryPoint)
            guard fileManager.fileExists(atPath: entry) else {
                return .failure(unloadableTypeScriptMessage)
            }
            return .success(tsdk)
        }
    }

    /// The value to send as `initializationOptions`, for a resolved `tsdk`.
    static func vueValue(tsdk: String) -> LSPValue {
        ["typescript": ["tsdk": .string(tsdk)]]
    }

    /// The same `tsdk`, on the command line, because version 3 of the Vue
    /// server reads it **only** from there.
    ///
    /// Measured against `@vue/language-server` 3.3.10 and 3.3.11: its entry
    /// point scans `process.argv` for `--tsdk=`, and falls back to
    /// `require('typescript')` when there is none. That fallback resolves to
    /// the peer copy npm installs beside the server, which today is
    /// TypeScript 7 — the native rewrite, which has no `tsserver` for the
    /// server to drive. The result is not an error: `initialize` answers
    /// normally, and then every request hangs unanswered, because the server
    /// never gets as far as asking `tsserver` which project the file belongs
    /// to. Sending `initializationOptions.typescript.tsdk`, which version 2
    /// read, changes nothing there — version 3 never looks at it.
    ///
    /// Both are sent. The option is what version 2 reads and the argument is
    /// what version 3 reads, and a machine can have either installed.
    static func vueTSDKArgument(tsdk: String) -> String {
        "--tsdk=\(tsdk)"
    }

    /// Shown when a `.vue` is opened in a project whose TypeScript cannot
    /// serve its `<script>` block.
    ///
    /// It names the version it found, because the advice depends on it and
    /// the two cases pull in opposite directions: with no TypeScript at all
    /// the answer is "install one", and with TypeScript 7 the answer is
    /// "install an older one", which nobody guesses.
    ///
    /// It also says Phantom **will not try**. That is the part a shorter
    /// message loses: silence and refusal look identical on screen, and a
    /// reader who thinks it was attempted goes looking for the failure.
    static func missingVueTypeScriptMessage(foundVersion: String?) -> String {
        let found = foundVersion.map {
            "This project has TypeScript \($0), which ships no tsserver for the plugin to load."
        } ?? "This project has no TypeScript of its own."

        return """
        \(found) Vue's <script> block needs TypeScript 6.x here, and Phantom \
        will not start a server for it until there is one — the template and \
        styles keep working. Install it with "npm i -D typescript@6 \
        @vue/typescript-plugin" in the project.
        """
    }

    /// `initializationOptions` for the TypeScript half of a `.vue`.
    ///
    /// `location` is absolute because the plugin resolves it through
    /// `URI.file(...)`, which has nothing to resolve a relative path against
    /// but the server's working directory.
    static func vuePluginValue(tsserverPath: String, pluginLocation: String) -> LSPValue {
        [
            "tsserver": ["path": .string(tsserverPath)],
            "plugins": [
                [
                    "name": .string("@vue/typescript-plugin"),
                    "location": .string(pluginLocation),
                    "languages": [.string("vue")],
                ],
            ],
        ]
    }

    /// The plugin options for a workspace, or the reason there are none.
    static func vueTypeScriptPlugin(
        root: String,
        searchPath: String = "",
        fileManager: FileManager = .default
    ) -> LSPOutcome<LSPValue> {
        guard case .tsserver(let tsserverPath) = TypeScriptToolchain.resolve(
            root: root,
            fileManager: fileManager
        ) else {
            return .failure(missingVueTypeScriptMessage(
                foundVersion: TypeScriptToolchain.localVersion(root: root, fileManager: fileManager)
            ))
        }

        guard let location = TypeScriptToolchain.vuePluginLocation(
            root: root,
            searchPath: searchPath,
            fileManager: fileManager
        ) else {
            return .failure("""
            Vue's <script> block needs @vue/typescript-plugin, and it is not \
            installed in this project. Install it with \
            "npm i -D @vue/typescript-plugin" — the template and styles keep \
            working without it.
            """)
        }

        return .success(vuePluginValue(tsserverPath: tsserverPath, pluginLocation: location))
    }
}
