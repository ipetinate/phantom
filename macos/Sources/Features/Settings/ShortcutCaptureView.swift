import AppKit
import SwiftUI

/// A shortcut that records itself: shows the current combination, and when
/// clicked waits for the next key pressed and adopts it.
///
/// Recording is done with a local event monitor rather than a text field on
/// purpose — a text field is how typos sneak in, and a shortcut typed wrong
/// is silent (nothing looks wrong until the key does nothing). Pressing the
/// keys is self-verifying: what you press is what you see.
struct ShortcutCaptureView: View {
    let action: PhantomShortcutAction
    @ObservedObject var store: PhantomShortcutStore

    @State private var isCapturing = false
    @State private var collisionMessage: String?
    @State private var monitor: Any?

    private var current: PhantomShortcut { store.shortcut(for: action) }

    var body: some View {
        LabeledContent(action.title) {
            Button {
                if isCapturing {
                    discardCapture()
                } else {
                    startCapture()
                }
            } label: {
                Text(isCapturing ? "Press keys…" : current.displayString)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 56)
            }
            .buttonStyle(.bordered)
            .help("Click, then press the key combination to assign")
        }
        .alert(
            "Shortcut already in use",
            isPresented: Binding(
                get: { collisionMessage != nil },
                set: { if !$0 { collisionMessage = nil } }
            )
        ) {
            Button("Change Shortcut") { startCapture() }
            Button("Discard", role: .cancel) { discardCapture() }
        } message: {
            Text(collisionMessage ?? "")
        }
        .onDisappear { stopMonitor() }
    }

    private func startCapture() {
        stopMonitor()
        isCapturing = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
        }
    }

    /// What to do with a key pressed while recording. A bare modifier (⌘ on
    /// its own, ⇧ on its own) is not a shortcut, so it passes through and
    /// recording keeps waiting; any real key ends recording.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let captured = PhantomShortcut(event: event) else { return event }
        guard captured.key != "\u{1B}" else {  // Escape cancels
            discardCapture()
            return nil
        }

        stopMonitor()
        isCapturing = false

        let other: (action: PhantomShortcutAction, shortcut: PhantomShortcut)?
        switch action {
        case .newFile: other = (.newFolder, store.newFolder)
        case .newFolder: other = (.newFile, store.newFile)
        }

        let collisions = ShortcutCollisionChecker.collisions(
            with: captured,
            excluding: current,
            otherPhantom: other,
            menu: NSApp.mainMenu
        )

        guard let first = collisions.first else {
            store.set(captured, for: action)
            return nil
        }

        collisionMessage = "“\(captured.displayString)” is already used by \(first.owner). Press the keys again for a different shortcut, or discard this change."
        return nil
    }

    private func discardCapture() {
        stopMonitor()
        isCapturing = false
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
