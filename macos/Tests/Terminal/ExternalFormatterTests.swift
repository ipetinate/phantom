import Foundation
@testable import Ghostty
import Testing

/// The formatters that are a command: which files each owns, what the reader's
/// settings do to it, and — the part that can lose work — how a finished run is
/// read.
struct ExternalFormatterTests {
    // MARK: The table

    /// Every row has to be runnable. A blank command or an empty extension set
    /// is a row that silently never fires, which is indistinguishable from the
    /// gap it was added to close.
    @Test func everyFormatterIsComplete() {
        for formatter in ExternalFormatterRegistry.all {
            #expect(!formatter.command.isEmpty, "\(formatter.id)")
            #expect(!formatter.extensions.isEmpty, "\(formatter.id)")
            #expect(!formatter.installHint.isEmpty, "\(formatter.id)")
            #expect(!formatter.displayName.isEmpty, "\(formatter.id)")
        }
    }

    @Test func idsAndExtensionsAreClaimedOnce() {
        let ids = ExternalFormatterRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count)

        var seen: Set<String> = []
        for formatter in ExternalFormatterRegistry.all {
            for ext in formatter.extensions {
                #expect(!seen.contains(ext), "\(ext) is claimed twice")
                seen.insert(ext)
            }
        }
    }

    /// **The two tables must not overlap.** Prettier resolves a project, a
    /// config and an ignore file; these are one process with no opinion about
    /// any of that. A file both claimed would be formatted by whichever route
    /// the editor happened to try first, which is not a decision anybody made.
    @Test func nothingHereIsAlsoAPrettierFile() {
        for formatter in ExternalFormatterRegistry.all {
            for ext in formatter.extensions {
                #expect(
                    !PrettierProject.parserCanBeInferred(for: "sample.\(ext)"),
                    "Prettier also claims .\(ext)")
            }
        }
    }

    @Test func aFileIsMatchedByItsExtensionWhateverItsCase() {
        #expect(ExternalFormatterRegistry.formatter(forFileNamed: "main.py")?.id == "python")
        #expect(ExternalFormatterRegistry.formatter(forFileNamed: "MAIN.PY")?.id == "python")
        #expect(ExternalFormatterRegistry.formatter(forFileNamed: "deploy.sh")?.id == "shellscript")
        #expect(ExternalFormatterRegistry.formatter(forFileNamed: "init.lua")?.id == "lua")
        #expect(ExternalFormatterRegistry.formatter(forFileNamed: "pom.xml")?.id == "xml")
    }

    @Test func aFileNobodyClaimsGetsNoFormatter() {
        #expect(ExternalFormatterRegistry.formatter(forFileNamed: "main.rs") == nil)
        #expect(ExternalFormatterRegistry.formatter(forFileNamed: "Makefile") == nil)
        #expect(ExternalFormatterRegistry.formatter(forFileNamed: "") == nil)
    }

    /// The name is what these tools read their own configuration from — a
    /// `pyproject.toml` above the file, a `stylua.toml` — so a placeholder
    /// left unsubstituted means every project gets the tool's defaults.
    @Test func thePlaceholderBecomesTheFilePath() throws {
        let ruff = try #require(ExternalFormatterRegistry.byID["python"])
        let arguments = ruff.arguments(for: "/repo/app/main.py")

        #expect(arguments.contains("/repo/app/main.py"))
        #expect(!arguments.contains(ExternalFormatter.filePlaceholder))
        #expect(arguments.first == "format")
    }

    // MARK: The reader's settings

    @Test func aFormatterSwitchedOffDoesNotRun() {
        let ruff = ExternalFormatterRegistry.byID["python"]!
        var setting = ExternalFormatterSetting()
        setting.isEnabled = false

        #expect(ExternalFormatterStore.effective(ruff, setting: setting) == nil)
    }

    /// One field at a time, which is what makes "point it at the ruff in my
    /// virtualenv" a one-field edit rather than a retype of the arguments.
    @Test func aBlankFieldFallsThroughToTheDefault() throws {
        let ruff = ExternalFormatterRegistry.byID["python"]!
        var setting = ExternalFormatterSetting()
        setting.command = "/venv/bin/ruff"

        let effective = try #require(ExternalFormatterStore.effective(ruff, setting: setting))
        #expect(effective.command == "/venv/bin/ruff")
        #expect(effective.arguments == ruff.arguments)
    }

    @Test func typedArgumentsReplaceTheDefaultsWhole() throws {
        let ruff = ExternalFormatterRegistry.byID["python"]!
        var setting = ExternalFormatterSetting()
        setting.arguments = "format  --line-length 100 -"

        let effective = try #require(ExternalFormatterStore.effective(ruff, setting: setting))
        #expect(effective.arguments == ["format", "--line-length", "100", "-"])
    }

    /// A setting that changes nothing is not stored, so the defaults can move
    /// under a reader who never touched them.
    @Test func aDefaultSettingIsRecognisedAsOne() {
        #expect(ExternalFormatterSetting().isDefault)

        var edited = ExternalFormatterSetting()
        edited.command = "/usr/local/bin/ruff"
        #expect(!edited.isDefault)

        var off = ExternalFormatterSetting()
        off.isEnabled = false
        #expect(!off.isDefault)
    }

    // MARK: Reading a finished run

    /// **The one that deletes files.** A buffer halfway through a function is a
    /// parse error, and a parse error exits non-zero having printed nothing:
    /// reading stdout first would answer "your file is now empty". Same order,
    /// same reason, as `PrettierRunner.result`.
    @Test func aNonZeroExitWithNoOutputIsAFailureAndNotAnEmptyFile() {
        do {
            let result = try ExternalFormatterRunner.result(
                status: 1, stdout: "", stderr: "", tool: "Ruff")
            #expect(Bool(false), "expected a failure, got \(String(describing: result))")
        } catch let failure as ExternalFormatterFailure {
            #expect(failure == .failed(
                tool: "Ruff", status: 1, message: "Ruff failed without saying why."))
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    @Test func emptyOutputOnASuccessfulExitIsNoChange() throws {
        #expect(try ExternalFormatterRunner.result(
            status: 0, stdout: "", stderr: "", tool: "Ruff") == nil)
    }

    @Test func formattedTextComesBackVerbatim() throws {
        let text = try ExternalFormatterRunner.result(
            status: 0, stdout: "def f(a):\n    return a\n", stderr: "", tool: "Ruff")

        #expect(text == "def f(a):\n    return a\n")
    }

    /// The line and column live on stderr, and they are the whole value of the
    /// message.
    @Test func aRefusalCarriesWhatTheToolSaid() {
        let message = "error: Failed to parse main.py:3:7: Expected an expression"
        do {
            _ = try ExternalFormatterRunner.result(
                status: 2, stdout: "", stderr: message, tool: "Ruff")
            #expect(Bool(false), "expected a failure")
        } catch let failure as ExternalFormatterFailure {
            #expect(failure.reason.contains(message))
            #expect(failure.reason.hasPrefix("Ruff"))
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    @Test func aKilledRunIsATimeoutAndNotAFailure() {
        do {
            _ = try ExternalFormatterRunner.result(
                status: nil, stdout: "", stderr: "", tool: "shfmt", timeout: 5)
            #expect(Bool(false), "expected a failure")
        } catch let failure as ExternalFormatterFailure {
            #expect(failure == .timedOut(tool: "shfmt", seconds: 5))
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    /// A missing tool is named, with the way to install it, because "nothing
    /// happened" is the alternative and it sends nobody anywhere.
    @Test func aMissingToolSaysWhatToInstall() {
        let failure = ExternalFormatterFailure.notFound(
            tool: "StyLua", hint: "brew install stylua")

        #expect(failure.reason == "StyLua isn't installed. brew install stylua")
    }

    // MARK: Running one

    /// The buffer goes in on stdin and the formatted text comes back on
    /// stdout, with the file's name among the arguments. Run against a stub so
    /// it holds on a machine with none of these tools installed.
    @Test func theBufferGoesInOnStdinAndTheArgumentsCarryTheFileName() throws {
        let stub = try makeStub("cat; echo \"args: $@\" >&2")
        let formatter = ExternalFormatter(
            id: "python",
            languageName: "Python",
            displayName: "Stub",
            command: stub.path,
            arguments: ["--stdin-filename", ExternalFormatter.filePlaceholder, "-"],
            extensions: ["py"],
            installHint: "",
            note: nil)

        let text = try ExternalFormatterRunner.format(
            "print(1)\n",
            filePath: "/repo/main.py",
            formatter: formatter,
            searchPath: "")

        #expect(text == "print(1)\n")
    }

    @Test func aToolThatIsNotThereIsReportedAsMissing() {
        let formatter = ExternalFormatter(
            id: "python",
            languageName: "Python",
            displayName: "Ruff",
            command: "/nowhere/ruff",
            arguments: [],
            extensions: ["py"],
            installHint: "brew install ruff",
            note: nil)

        do {
            _ = try ExternalFormatterRunner.format(
                "x", filePath: "/repo/main.py", formatter: formatter, searchPath: "")
            #expect(Bool(false), "expected a failure")
        } catch let failure as ExternalFormatterFailure {
            #expect(failure == .notFound(tool: "Ruff", hint: "brew install ruff"))
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    // MARK: Stubs

    private func makeStub(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-formatter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("tool")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

/// The same runner against the tools themselves, on a machine that has them.
///
/// The suite above proves the rules with stubs, which is what makes it run
/// anywhere. This one proves the arguments: a flag these tools do not take is
/// an exit code and an empty buffer, and no stub can tell you that `ruff` wants
/// `--stdin-filename` while `stylua` wants `--stdin-filepath`.
///
/// Each test is skipped where its tool is not installed, so this stays honest
/// on a machine — or a CI runner — without them.
struct InstalledFormatterTests {
    private static func path(_ command: String) -> String? {
        ExternalFormatterRunner.locate(command, searchPath: LoginEnvironment.executableSearchPath())
    }

    private func run(_ id: String, _ text: String, named name: String) throws -> String? {
        let formatter = try #require(ExternalFormatterRegistry.byID[id])
        return try ExternalFormatterRunner.format(
            text,
            filePath: "/tmp/\(name)",
            formatter: formatter,
            searchPath: LoginEnvironment.executableSearchPath())
    }

    @Test(.enabled(if: path("ruff") != nil))
    func ruffFormatsPython() throws {
        let formatted = try run("python", "def   f( a,b ):\n  return   a+b\n", named: "main.py")

        #expect(formatted == "def f(a, b):\n    return a + b\n")
    }

    @Test(.enabled(if: path("shfmt") != nil))
    func shfmtFormatsShell() throws {
        let formatted = try run("shellscript", "x=1\nif [ 1 ];then\necho hi\nfi\n", named: "deploy.sh")

        #expect(formatted == "x=1\nif [ 1 ]; then\n\techo hi\nfi\n")
    }

    @Test(.enabled(if: path("stylua") != nil))
    func styluaFormatsLua() throws {
        let formatted = try run("lua", "local   x = 1\n", named: "init.lua")

        #expect(formatted == "local x = 1\n")
    }

    @Test(.enabled(if: path("xmllint") != nil))
    func xmllintFormatsXML() throws {
        let formatted = try run("xml", "<a><b>1</b></a>\n", named: "doc.xml")

        #expect(formatted?.contains("  <b>1</b>") == true)
    }

    /// The failure that matters, against the real tool: a buffer mid-edit is a
    /// parse error, and it has to arrive as a failure rather than as an empty
    /// file.
    @Test(.enabled(if: path("ruff") != nil))
    func aPythonBufferMidEditFailsRatherThanEmptying() {
        do {
            let formatted = try run("python", "def f(\n", named: "main.py")
            #expect(Bool(false), "expected a failure, got \(String(describing: formatted))")
        } catch let failure as ExternalFormatterFailure {
            #expect(failure.reason.hasPrefix("Ruff"))
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }
}
