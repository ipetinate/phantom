import Foundation
@testable import Ghostty
import Testing

/// Reading `~/.codex/hooks.json` before rewriting it.
///
/// The bug this pins down: a present-but-invalid file read as *nothing*, and
/// the installer then wrote its own six hooks over it — atomically, and
/// while reporting success. One stray character in a hand-edited config was
/// enough to lose the whole thing, with no copy left anywhere.
///
/// Only the read half is exercised. `install()` and `uninstall()` resolve
/// their own path from `codexDir`, so testing them would mean either a
/// test-only seam on a production singleton or writing to the user's real
/// Codex configuration during a test run — both worse than the gap. What
/// they do with the answer is one line each: `guard var settings =
/// readSettings() else { return fail(…) }`.
@MainActor
struct CodexHooksInstallerTests {
    private func temporaryFile(_ contents: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-codex-\(UUID().uuidString).json")
        if let contents {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// No file yet is the ordinary first install, and an empty dictionary is
    /// the configuration this may create.
    @Test func anAbsentFileReadsAsAnEmptyConfiguration() throws {
        let url = try temporaryFile(nil)
        let settings = CodexHooksInstaller.readSettings(at: url)

        #expect(settings != nil)
        #expect(settings?.isEmpty == true)
    }

    @Test func aValidObjectIsReadBackWhole() throws {
        let url = try temporaryFile(#"{"hooks":{"Stop":[]},"model":"gpt-5"}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        let settings = CodexHooksInstaller.readSettings(at: url)
        #expect(settings?["model"] as? String == "gpt-5")
        #expect(settings?["hooks"] != nil)
    }

    /// The one that mattered: nil, so the caller refuses to write.
    @Test func malformedJSONRefusesToBeRead() throws {
        let url = try temporaryFile(#"{"hooks": {"Stop": [}}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(CodexHooksInstaller.readSettings(at: url) == nil)
    }

    /// Valid JSON, wrong shape. This parsed and then failed the cast, which
    /// is the same nil and the same refusal.
    @Test func aTopLevelArrayRefusesToBeRead() throws {
        let url = try temporaryFile(#"[{"hooks":{}}]"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(CodexHooksInstaller.readSettings(at: url) == nil)
    }

    @Test func plainTextRefusesToBeRead() throws {
        let url = try temporaryFile("# not json at all\n")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(CodexHooksInstaller.readSettings(at: url) == nil)
    }

    /// A zero-byte file is a file nobody has written yet, not one this
    /// can't understand — refusing there would make the installer
    /// permanently unusable after a `touch`.
    @Test func anEmptyFileReadsAsAnEmptyConfiguration() throws {
        let url = try temporaryFile("")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(CodexHooksInstaller.readSettings(at: url)?.isEmpty == true)
    }
}
