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

    /// The value to send as `initializationOptions`, for a resolved `tsdk`.
    static func vueValue(tsdk: String) -> LSPValue {
        ["typescript": ["tsdk": .string(tsdk)]]
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
