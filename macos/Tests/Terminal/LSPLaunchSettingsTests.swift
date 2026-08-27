import Foundation
@testable import Ghostty
import Testing

/// The `--tsdk` argument, and the process arguments it ends up in.
///
/// Version 3 of `@vue/language-server` reads the path to TypeScript from its
/// command line and from nowhere else. Measured against 3.3.10 and 3.3.11
/// with the argument left off: `initialize` answers normally and then every
/// request goes unanswered, because the fallback `require('typescript')`
/// finds the TypeScript 7 npm installs beside the server — the native
/// rewrite, which ships no `tsserver` for it to drive.
struct LSPLaunchSettingsTests {
    @Test func theArgumentCarriesTheResolvedPath() {
        let argument = LSPInitializationOptions.vueTSDKArgument(tsdk: "/w/node_modules/typescript/lib")
        #expect(argument == "--tsdk=/w/node_modules/typescript/lib")
    }

    /// Both spellings of the same fact are sent, because a machine can have
    /// either major version of the server installed and each reads only one
    /// of them.
    @Test func theOptionAndTheArgumentNameTheSamePath() {
        let tsdk = "/w/node_modules/typescript/lib"
        #expect(LSPInitializationOptions.vueValue(tsdk: tsdk)["typescript"]?["tsdk"] == .string(tsdk))
        #expect(LSPInitializationOptions.vueTSDKArgument(tsdk: tsdk).hasSuffix(tsdk))
    }

    @Test func launchSettingsCarryNoArgumentsByDefault() {
        #expect(LSPLaunchSettings().arguments.isEmpty)
        #expect(LSPLaunchSettings().initializationOptions == nil)
    }

    /// The definition's own arguments come first, the workspace's after —
    /// the order a command line is read in.
    @Test func extraArgumentsAreAppendedToTheDefinitions() {
        let process = LSPProcess(
            definition: LSPServerRegistry.server(forLanguage: "vue")!,
            extraArguments: ["--tsdk=/w/node_modules/typescript/lib"],
            environmentProvider: { [:] }
        )

        #expect(process.definition.arguments == ["--stdio"])
        #expect(process.extraArguments == ["--tsdk=/w/node_modules/typescript/lib"])
    }

    /// The Vue server is the one definition that asks for the lookup, and
    /// the TypeScript half deliberately is not: it takes the same project's
    /// `tsserver.js` through `initializationOptions` instead.
    @Test func onlyTheVueServerAsksForTheSDKLookup() {
        #expect(LSPServerRegistry.server(forLanguage: "vue")?.initializationOptionsKind == .vueTypeScriptSDK)
        #expect(LSPServerRegistry.vueTypeScriptServer.initializationOptionsKind == .vueTypeScriptPlugin)
    }

    /// A `tsdk` directory that exists but holds nothing loadable is refused
    /// with a sentence, not passed on. Since the path became a launch
    /// argument, version 3 of the server resolves it before it can report
    /// anything itself — so the process would die silently instead.
    @Test func anEmptyTypeScriptDirectoryIsRefused() {
        let root = NSTemporaryDirectory() + "phantom-tsdk-\(UUID().uuidString)"
        let lib = root + "/node_modules/typescript/lib"
        try? FileManager.default.createDirectory(atPath: lib, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        switch LSPInitializationOptions.vueLoadableTypeScriptSDK(root: root, searchPath: "") {
        case .success(let path): Issue.record("expected a refusal, got \(path)")
        case .failure(let reason):
            #expect(reason == LSPInitializationOptions.unloadableTypeScriptMessage)
        }
    }

    /// The same directory with the file the server loads is accepted.
    @Test func aTypeScriptDirectoryWithItsLibraryIsAccepted() {
        let root = NSTemporaryDirectory() + "phantom-tsdk-\(UUID().uuidString)"
        let lib = root + "/node_modules/typescript/lib"
        try? FileManager.default.createDirectory(atPath: lib, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: lib + "/typescript.js", contents: Data())
        defer { try? FileManager.default.removeItem(atPath: root) }

        switch LSPInitializationOptions.vueLoadableTypeScriptSDK(root: root, searchPath: "") {
        case .success(let path): #expect(path == lib)
        case .failure(let reason): Issue.record("expected the local path, got \(reason)")
        }
    }
}
