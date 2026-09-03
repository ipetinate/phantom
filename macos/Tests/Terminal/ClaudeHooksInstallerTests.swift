import Foundation
@testable import Ghostty
import Testing

/// Exercises the JSON-shape half of `ClaudeHooksInstaller.isInstalled`
/// against in-memory fixtures. The path-resolution half (`claudeDir`,
/// derived from `homeDirectoryForCurrentUser`) has no injectable seam, and
/// adding one only for this would mean either mutable test-only state on a
/// production singleton or touching the user's real `~/.claude/settings.json`
/// during tests — both worse than the gap. What's covered here is exactly
/// the class of bug that shipped: `isInstalled` searching raw file text for
/// an unescaped path against JSON where `JSONSerialization` escapes `/`.
@MainActor
struct ClaudeHooksInstallerTests {
    private let scriptName = ClaudeHooksInstaller.scriptName

    /// A settings file registering the script for one event only — `Stop`.
    private func hooksSettings(registeredCommand: String?) -> [String: Any] {
        var hooks: [String: Any] = [:]
        if let registeredCommand {
            hooks["Stop"] = [
                [
                    "hooks": [
                        ["type": "command", "command": registeredCommand],
                    ]
                ]
            ]
        }
        return ["hooks": hooks]
    }

    /// A settings file registering the script for every event this build
    /// reports — what a current install actually leaves behind.
    private func fullyRegisteredSettings(
        omitting omitted: Set<String> = []
    ) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for (event, state) in ClaudeHooksInstaller.eventStates where !omitted.contains(event) {
            hooks[event] = [
                ["hooks": [["type": "command", "command": "'/h/\(scriptName)' \(state)"]]]
            ]
        }
        return ["hooks": hooks]
    }

    @Test func detectsARegisteredHookRegardlessOfJSONEscaping() {
        // JSONSerialization escapes "/" as "\/" on disk; the parsed dict
        // handed to this function always has it unescaped, same as this.
        let path = "/Users/isac.petinate/.claude/hooks/\(scriptName)"
        let settings = hooksSettings(registeredCommand: "'\(path)' done")
        #expect(ClaudeHooksInstaller.isRegisteredForAnyEvent(
            in: settings, scriptName: scriptName))
    }

    @Test func noHooksKeyIsNotRegistered() {
        #expect(!ClaudeHooksInstaller.isRegistered(in: [:], scriptName: scriptName))
        #expect(!ClaudeHooksInstaller.isRegisteredForAnyEvent(
            in: [:], scriptName: scriptName))
    }

    @Test func emptyHooksAreNotRegistered() {
        let settings = hooksSettings(registeredCommand: nil)
        #expect(!ClaudeHooksInstaller.isRegistered(in: settings, scriptName: scriptName))
        #expect(!ClaudeHooksInstaller.isRegisteredForAnyEvent(
            in: settings, scriptName: scriptName))
    }

    @Test func aDifferentCommandIsNotRegistered() {
        let settings = hooksSettings(registeredCommand: "'/some/other/script.sh' done")
        #expect(!ClaudeHooksInstaller.isRegistered(in: settings, scriptName: scriptName))
        #expect(!ClaudeHooksInstaller.isRegisteredForAnyEvent(
            in: settings, scriptName: scriptName))
    }

    /// `readSettings()` returns nil when the file is missing or the JSON
    /// fails to parse; this is what every caller sees in that case.
    @Test func missingOrInvalidSettingsIsNotRegistered() {
        #expect(!ClaudeHooksInstaller.isRegistered(in: nil, scriptName: scriptName))
        #expect(!ClaudeHooksInstaller.isRegisteredForAnyEvent(
            in: nil, scriptName: scriptName))
    }

    @Test func aRegisteredHookAmongUnrelatedKeysIsStillDetected() {
        var settings = fullyRegisteredSettings()
        settings["env"] = ["SOME_VAR": "value"]
        settings["theme"] = "dark"
        #expect(ClaudeHooksInstaller.isRegistered(in: settings, scriptName: scriptName))
    }

    // MARK: - Complete vs. partial registration

    @Test func everyEventRegisteredCountsAsInstalled() {
        #expect(ClaudeHooksInstaller.isRegistered(
            in: fullyRegisteredSettings(), scriptName: scriptName))
    }

    /// The bug: one event out of nine used to satisfy the check. An install
    /// performed by an older Phantom therefore counted as current forever, so
    /// the events added since were never registered — and the states behind
    /// them became unreachable. No `notify` write means
    /// `TabStateCenter.handleAttentionMarker` can never run, so the system
    /// notification never fires; no `StopFailure` or `PermissionDenied` means
    /// the `failed` and `denied` indicators never appear.
    @Test func aPartialRegistrationIsNotInstalled() {
        let partial = fullyRegisteredSettings(
            omitting: ["Notification", "PermissionDenied", "StopFailure"])
        #expect(!ClaudeHooksInstaller.isRegistered(in: partial, scriptName: scriptName))
    }

    /// Exactly the shape found in the user's `settings.json`: six events
    /// registered, which the old check called installed. Three were added to
    /// this build after their install (`Notification`, `PermissionDenied`,
    /// `StopFailure`), `SessionStart` after that and `PreCompact` after that,
    /// so six of twelve.
    @Test func thePartialInstallationFoundInTheWildIsDetectedAsIncomplete() {
        let partial = fullyRegisteredSettings(omitting: [
            "SessionStart", "PreCompact", "PostCompact", "Notification",
            "PermissionDenied", "StopFailure",
        ])
        let registered = (partial["hooks"] as? [String: Any])?.count
        #expect(registered == 6)
        #expect(ClaudeHooksInstaller.eventStates.count == 12)
        #expect(!ClaudeHooksInstaller.isRegistered(in: partial, scriptName: scriptName))
        // Still "registered for something", which is what tells repair that the
        // user asked for this integration rather than that it should install
        // itself uninvited.
        #expect(ClaudeHooksInstaller.isRegisteredForAnyEvent(
            in: partial, scriptName: scriptName))
    }

    /// Removal has to leave nothing behind, and `!isRegistered` cannot express
    /// that: a single missing event satisfies it while eight live hooks still
    /// point at a script that has been deleted.
    @Test func aPartialRemovalIsNotACompleteRemoval() {
        let partial = fullyRegisteredSettings(omitting: ["Stop"])
        #expect(!ClaudeHooksInstaller.isRegistered(in: partial, scriptName: scriptName))
        #expect(ClaudeHooksInstaller.isRegisteredForAnyEvent(
            in: partial, scriptName: scriptName))
    }

    @Test func removingEveryEventLeavesNothingRegistered() {
        let empty = fullyRegisteredSettings(
            omitting: Set(ClaudeHooksInstaller.eventStates.map(\.event)))
        #expect(!ClaudeHooksInstaller.isRegisteredForAnyEvent(
            in: empty, scriptName: scriptName))
    }
}
