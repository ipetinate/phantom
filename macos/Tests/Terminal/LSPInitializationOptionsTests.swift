import Foundation
@testable import Ghostty
import Testing

/// Resolving Volar's `tsdk` — the one piece of `initializationOptions`
/// this app builds automatically today.
///
/// `searchPath` is always passed explicitly here rather than left to
/// resolve from the login shell: a test that shells out to whatever `npm`
/// happens to be on the machine running it would pass or fail depending on
/// the developer's own setup, which is exactly the nondeterminism a test
/// exists to rule out.
struct LSPInitializationOptionsTests {
    private func makeDirectory() -> String {
        let directory = NSTemporaryDirectory() + "phantom-tsdk-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The project's own copy wins over the global one, so a workspace that
    /// pins a version is checked against that version.
    @Test func aProjectLocalTypeScriptWinsOverTheGlobalOne() {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let local = root + "/node_modules/typescript/lib"
        try? FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)

        // An empty search path means `npm` itself can never be found, so a
        // success here can only have come from the local check.
        switch LSPInitializationOptions.vueTypeScriptSDK(root: root, searchPath: "") {
        case .success(let path): #expect(path == local)
        case .failure(let reason): Issue.record("expected the local path, got failure: \(reason)")
        }
    }

    /// Neither a local install nor a resolvable `npm` on `PATH` produces the
    /// concrete message this feature exists to show instead of silence.
    @Test func neitherLocalNorGlobalProducesTheNamedFailure() {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }

        switch LSPInitializationOptions.vueTypeScriptSDK(root: root, searchPath: "") {
        case .success(let path): Issue.record("expected failure, got a path: \(path)")
        case .failure(let reason): #expect(reason == LSPInitializationOptions.missingTypeScriptMessage)
        }
    }

    /// The value shape Volar's own docs specify: nested under `typescript`,
    /// not sent as a bare string.
    @Test func theValueNestsTsdkUnderTypescript() {
        let value = LSPInitializationOptions.vueValue(tsdk: "/path/to/lib")
        #expect(value["typescript"]?["tsdk"]?.stringValue == "/path/to/lib")
    }

    // MARK: The formatter the vscode servers keep switched off

    /// The flag's name and shape, spelled the way the three servers read it.
    /// Measured: with it, each of the three answers `initialize` with
    /// `documentFormattingProvider: true`; without it, all three say false.
    @Test func theFormatterFlagIsSentAtTheTopLevel() {
        #expect(LSPInitializationOptions.provideFormatterValue["provideFormatter"]?.boolValue == true)
    }

    /// Every server from `vscode-langservers-extracted` carries the flag, and
    /// missing one means that language silently has no formatter — which is
    /// how JSON, HTML and CSS came to have none.
    @Test func everyVSCodeServerAsksForItsFormatter() {
        let extracted = LSPServerRegistry.all.filter {
            $0.installHint.contains("vscode-langservers-extracted")
        }

        #expect(extracted.count == 5)
        for definition in extracted {
            #expect(
                definition.initializationOptionsKind == .provideFormatter,
                "\(definition.languageID)")
        }
    }

    /// And nothing else does. The flag means one thing to three servers and
    /// nothing to the rest, so sending it more widely would be sending noise
    /// no server asked for.
    @Test func noOtherServerSendsTheFormatterFlag() {
        let others = LSPServerRegistry.all.filter {
            !$0.installHint.contains("vscode-langservers-extracted")
        }

        #expect(others.allSatisfy { $0.initializationOptionsKind != .provideFormatter })
    }
}
