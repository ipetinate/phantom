import SwiftUI

/// Where the app's configurable shortcuts live.
///
/// A shortcut is captured by pressing keys, never typed — see
/// `ShortcutCaptureView` — and every capture is checked against the live
/// menu (which includes the user's Ghostty keybindings) before it sticks.
struct KeyboardShortcutsSettingsView: View {
    @ObservedObject private var shortcuts = PhantomShortcutStore.shared

    var body: some View {
        Form {
            Section {
                ShortcutCaptureView(action: .newFile, store: shortcuts)
                ShortcutCaptureView(action: .newFolder, store: shortcuts)
            } header: {
                Text("File Explorer")
            } footer: {
                Text("These create a file or folder in the file explorer at the current selection — inside a selected folder, or beside a selected file. Click a shortcut and press the new keys to record it. If the combination is already used elsewhere, you'll be asked to choose again or discard the change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Keyboard Shortcuts")
    }
}
