import Foundation
@testable import Ghostty
import Testing

/// Preferences that are shown in two places at once.
///
/// The file explorer's root mode and hidden-files switch live in its gear
/// menu and, since the Settings audit, in the Editor pane as well. Both
/// write the same `UserDefaults` key — but `FileExplorerModel` reads that
/// key once, in its initializer, and publishes its own copy. So a write
/// from the other surface used to land in `UserDefaults` and nowhere else:
/// the switch in Settings moved, the tree kept its dotfiles, and the gear
/// menu still showed the old answer until the window was reopened. These
/// cover the observation that closes that gap.
@MainActor
@Suite(.serialized)
struct FileExplorerSharedPreferenceTests {
    /// Notification delivery is queued on the main queue, so the assertion
    /// has to give the run loop a turn. Bounded, so a broken observer fails
    /// the test instead of hanging the suite.
    private func settle(until satisfied: () -> Bool) async {
        for _ in 0..<100 where !satisfied() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func anOpenExplorerTakesAHiddenFilesChangeMadeElsewhere() async {
        let key = FileExplorerModel.showHiddenKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        UserDefaults.standard.set(true, forKey: key)
        let model = FileExplorerModel()
        #expect(model.showHiddenFiles)

        UserDefaults.standard.set(false, forKey: key)
        await settle { !model.showHiddenFiles }
        #expect(!model.showHiddenFiles)
    }

    @Test func anOpenExplorerTakesARootModeChangeMadeElsewhere() async {
        let key = WorkspaceRootMode.defaultsKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        UserDefaults.standard.set(WorkspaceRootMode.auto.rawValue, forKey: key)
        let model = FileExplorerModel()
        #expect(model.rootMode == .auto)

        UserDefaults.standard.set(WorkspaceRootMode.repository.rawValue, forKey: key)
        await settle { model.rootMode == .repository }
        #expect(model.rootMode == .repository)
    }

    /// Adopting a root mode has to re-resolve the root, or the tree keeps
    /// showing the folder the old mode chose — the callback is the whole
    /// point of the property, and a plain assignment that skipped it would
    /// look right in the menu and wrong on screen.
    @Test func adoptingARootModeAsksForTheRootAgain() async {
        let key = WorkspaceRootMode.defaultsKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        UserDefaults.standard.set(WorkspaceRootMode.auto.rawValue, forKey: key)
        let model = FileExplorerModel()

        var asked = false
        model.onRootModeChanged = { asked = true }

        UserDefaults.standard.set(WorkspaceRootMode.terminalFolder.rawValue, forKey: key)
        await settle { asked }
        #expect(asked)
    }

    /// A write to some unrelated key must not disturb either property.
    /// The observer fires on every defaults change in the process, which is
    /// constantly, so the compare-before-assign is what keeps that from
    /// being a listing reload per keystroke somewhere else in the app.
    @Test func anUnrelatedDefaultsWriteChangesNothing() async {
        let key = FileExplorerModel.showHiddenKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        UserDefaults.standard.set(false, forKey: key)
        let model = FileExplorerModel()

        var asked = false
        model.onRootModeChanged = { asked = true }

        UserDefaults.standard.set("anything", forKey: "SettingsMirrorTestsScratch")
        defer { UserDefaults.standard.removeObject(forKey: "SettingsMirrorTestsScratch") }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!model.showHiddenFiles)
        #expect(!asked)
    }
}

/// The font picker's "Monospaced only" filter, which used to be `@State`
/// and came back ticked on every open — so anyone whose font macOS
/// mis-reports as proportional had to untick it again every single time.
struct FontPickerPreferenceTests {
    /// Pinned, because the promise made when this stopped being `@State`
    /// was that nobody would have to migrate anything. Renaming the key
    /// silently forgets what everyone has chosen.
    @Test func theKeyIsStable() {
        #expect(FontPickerView.monospacedOnlyKey == "FontPickerMonospacedOnly")
    }
}
