import SwiftUI

/// Where the app's configurable shortcuts live.
///
/// Every command Phantom owns is listed, grouped by the surface that answers
/// to it, and every one of them may hold several shortcuts — see
/// `ShortcutCaptureView` for the recording, and `ShortcutCollisionChecker`
/// for what a combination is checked against before it sticks.
///
/// The list is driven off `PhantomShortcutAction.allCases` rather than
/// spelled out, so a new command appears here by existing.
struct KeyboardShortcutsSettingsView: View {
    @ObservedObject private var shortcuts = PhantomShortcutStore.shared

    var body: some View {
        Form {
            ForEach(PhantomShortcutGroup.allCases) { group in
                Section {
                    ForEach(PhantomShortcutAction.actions(in: group)) { action in
                        ShortcutCaptureView(action: action, store: shortcuts)
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    Text(group.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Keyboard Shortcuts")
    }
}
