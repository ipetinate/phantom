import Foundation
@testable import Ghostty
import Testing

/// The rule being tested is narrow on purpose: move the server's own JVM,
/// leave the build's alone, and change nothing at all unless both halves of
/// that are possible.
///
/// The JDKs here are directories with a `release` file and an executable
/// `bin/java`, which is what the code actually looks for — a fixture that
/// asserted on directory *names* would pass while the real discovery, which
/// refuses a name that can't execute a JVM, failed.
struct LSPJavaRuntimeTests {
    // MARK: Version parsing

    @Test func readsFeatureVersionFromAModernVersionString() {
        #expect(LSPJavaRuntime.featureVersion(ofVersionString: "25.0.3") == 25)
        #expect(LSPJavaRuntime.featureVersion(ofVersionString: "21.0.12") == 21)
        #expect(LSPJavaRuntime.featureVersion(ofVersionString: "17") == 17)
    }

    @Test func readsFeatureVersionFromThePre9Spelling() {
        #expect(LSPJavaRuntime.featureVersion(ofVersionString: "1.8.0_452") == 8)
        #expect(LSPJavaRuntime.featureVersion(ofVersionString: "1.7.0") == 7)
    }

    @Test func refusesAVersionStringItCannotRead() {
        #expect(LSPJavaRuntime.featureVersion(ofVersionString: "") == nil)
        #expect(LSPJavaRuntime.featureVersion(ofVersionString: "corretto") == nil)
    }

    @Test func readsTheVersionOutOfAJDKsReleaseFile() throws {
        let root = try TemporaryDirectory()
        let home = try root.makeJavaHome(named: "jdk-21", version: "21.0.12")

        #expect(LSPJavaRuntime.featureVersion(ofJavaHome: home) == 21)
    }

    @Test func hasNoVersionForADirectoryThatIsNotAJDK() throws {
        let root = try TemporaryDirectory()

        #expect(LSPJavaRuntime.featureVersion(ofJavaHome: root.path) == nil)
    }

    // MARK: Choosing a JDK

    @Test func picksTheNewestJDKThatIsStillUnderTheCeiling() throws {
        let root = try TemporaryDirectory()
        let old = try root.makeJavaHome(named: "jdk-8", version: "1.8.0_452")
        let fits = try root.makeJavaHome(named: "jdk-21", version: "21.0.12")
        let tooNew = try root.makeJavaHome(named: "jdk-25", version: "25.0.3")

        let chosen = LSPJavaRuntime.newestJavaHome(upTo: 21, among: [old, tooNew, fits])

        #expect(chosen == fits)
    }

    @Test func hasNoJDKToOfferWhenEveryInstalledOneIsTooNew() throws {
        let root = try TemporaryDirectory()
        let tooNew = try root.makeJavaHome(named: "jdk-25", version: "25.0.3")

        #expect(LSPJavaRuntime.newestJavaHome(upTo: 21, among: [tooNew]) == nil)
    }

    // MARK: Discovery

    @Test func findsJDKsInABundleAndInAPlainDirectory() throws {
        let root = try TemporaryDirectory()
        let plain = try root.makeJavaHome(named: "sdkman-21", version: "21.0.12")
        let bundle = try root.makeJavaHome(named: "temurin-17.jdk/Contents/Home", version: "17.0.9")

        let found = LSPJavaRuntime.installedJavaHomes(
            searchRoots: [LSPJavaRuntime.SearchRoot(path: root.path)]
        )

        #expect(Set(found) == [plain, bundle])
    }

    @Test func findsAJDKNestedOneLevelDeeperWhenTheRootSaysItIs() throws {
        let root = try TemporaryDirectory()
        let nested = try root.makeJavaHome(
            named: "amazon-25-aarch64/amazon-corretto-25.jdk/Contents/Home",
            version: "25.0.2"
        )

        let withoutNesting = LSPJavaRuntime.installedJavaHomes(
            searchRoots: [LSPJavaRuntime.SearchRoot(path: root.path)]
        )
        let withNesting = LSPJavaRuntime.installedJavaHomes(
            searchRoots: [LSPJavaRuntime.SearchRoot(path: root.path, nesting: 1)]
        )

        #expect(withoutNesting.isEmpty)
        #expect(withNesting == [nested])
    }

    @Test func ignoresADirectoryThatCannotExecuteAJVM() throws {
        let root = try TemporaryDirectory()
        try root.makeJavaHome(named: "half-extracted", version: "21.0.12", executable: false)

        let found = LSPJavaRuntime.installedJavaHomes(
            searchRoots: [LSPJavaRuntime.SearchRoot(path: root.path)]
        )

        #expect(found.isEmpty)
    }

    // MARK: The environment handed to a server

    @Test func leavesTheEnvironmentAloneForAServerThatDeclaresNoCeiling() throws {
        let root = try TemporaryDirectory()
        let fits = try root.makeJavaHome(named: "jdk-21", version: "21.0.12")
        let tooNew = try root.makeJavaHome(named: "jdk-25", version: "25.0.3")

        let adjusted = LSPJavaRuntime.adjustedEnvironment(
            ["JAVA_HOME": tooNew],
            for: definition(ceiling: nil),
            installedHomes: { [fits] }
        )

        #expect(adjusted == ["JAVA_HOME": tooNew])
    }

    @Test func leavesTheEnvironmentAloneWhenTheInheritedJDKIsLowEnough() throws {
        let root = try TemporaryDirectory()
        let fits = try root.makeJavaHome(named: "jdk-21", version: "21.0.12")
        let older = try root.makeJavaHome(named: "jdk-17", version: "17.0.9")

        let adjusted = LSPJavaRuntime.adjustedEnvironment(
            ["JAVA_HOME": fits],
            for: definition(ceiling: 21),
            installedHomes: { [older, fits] }
        )

        #expect(adjusted == ["JAVA_HOME": fits])
    }

    @Test func leavesTheEnvironmentAloneWhenNothingOlderIsInstalled() throws {
        let root = try TemporaryDirectory()
        let tooNew = try root.makeJavaHome(named: "jdk-25", version: "25.0.3")

        let adjusted = LSPJavaRuntime.adjustedEnvironment(
            ["JAVA_HOME": tooNew],
            for: definition(ceiling: 21),
            installedHomes: { [tooNew] }
        )

        #expect(adjusted == ["JAVA_HOME": tooNew])
    }

    @Test func movesTheServerAndHandsTheInheritedJDKToGradle() throws {
        let root = try TemporaryDirectory()
        let fits = try root.makeJavaHome(named: "jdk-21", version: "21.0.12")
        let tooNew = try root.makeJavaHome(named: "jdk-25", version: "25.0.3")

        let adjusted = LSPJavaRuntime.adjustedEnvironment(
            ["JAVA_HOME": tooNew, "PATH": "/usr/bin"],
            for: definition(ceiling: 21),
            installedHomes: { [fits, tooNew] }
        )

        #expect(adjusted["JAVA_HOME"] == fits)
        #expect(adjusted["GRADLE_OPTS"] == "-Dorg.gradle.java.home=\(tooNew)")
        #expect(adjusted["PATH"] == "/usr/bin")
    }

    // MARK: GRADLE_OPTS

    @Test func keepsWhateverElseGradleOptsAlreadyCarried() {
        let options = LSPJavaRuntime.gradleOptions(
            preserving: "/jdk-25",
            in: "-Xmx4g"
        )

        #expect(options == "-Dorg.gradle.java.home=/jdk-25 -Xmx4g")
    }

    @Test func doesNotOverruleADeveloperWhoAlreadyNamedTheDaemonsJDK() {
        let existing = "-Dorg.gradle.java.home=/somewhere/else"
        let options = LSPJavaRuntime.gradleOptions(preserving: "/jdk-25", in: existing)

        #expect(options == existing)
    }

    @Test func quotesAPathThatWouldOtherwiseSplitIntoTwoArguments() {
        let options = LSPJavaRuntime.gradleOptions(
            preserving: "/Library/Java/Amazon Corretto 25.jdk/Contents/Home",
            in: nil
        )

        #expect(options == "-Dorg.gradle.java.home=\"/Library/Java/Amazon Corretto 25.jdk/Contents/Home\"")
    }

    // MARK: Fixtures

    private func definition(ceiling: Int?) -> LSPServerDefinition {
        LSPServerDefinition(
            languageID: "kotlin",
            displayName: "Kotlin Language Server",
            command: "kotlin-language-server",
            arguments: [],
            installHint: "brew install kotlin-language-server",
            maximumJavaFeatureVersion: ceiling
        )
    }
}

/// A directory that removes itself, and can be filled with JDK-shaped
/// directories.
private final class TemporaryDirectory {
    let path: String

    init() throws {
        path = NSTemporaryDirectory().appending("lsp-java-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Creates a JDK at `named`, relative to this directory, and answers its
    /// home. `executable: false` produces the one case discovery has to
    /// reject: a tree that looks right and cannot run a JVM.
    @discardableResult
    func makeJavaHome(named name: String, version: String, executable: Bool = true) throws -> String {
        let home = (path as NSString).appendingPathComponent(name)
        let binary = (home as NSString).appendingPathComponent("bin/java")

        try FileManager.default.createDirectory(
            atPath: (binary as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: binary,
            contents: Data(),
            attributes: executable ? [.posixPermissions: 0o755] : [.posixPermissions: 0o644]
        )
        try "JAVA_VERSION=\"\(version)\"\n".write(
            toFile: (home as NSString).appendingPathComponent("release"),
            atomically: true,
            encoding: .utf8
        )
        return home
    }
}
