import AppKit
import SwiftUI

/// One command's row in Settings: every shortcut it answers to, a way to add
/// another, a way to take one away, and a way to put the defaults back.
///
/// Shortcuts are recorded by pressing keys, never typed. Recording is done
/// with a local event monitor rather than a text field on purpose — a text
/// field is how typos sneak in, and a shortcut typed wrong is silent
/// (nothing looks wrong until the key does nothing). Pressing the keys is
/// self-verifying: what you press is what you see.
///
/// Every capture is checked against the live menu (which includes the user's
/// Ghostty keybindings), the fixed pane keys, and the other commands —
/// including this same command's own list, since the same combination twice
/// is a no-op worth saying out loud rather than a second entry.
struct ShortcutCaptureView: View {
    let action: PhantomShortcutAction
    @ObservedObject var store: PhantomShortcutStore

    /// Which entry the recorder is filling.
    ///
    /// Kept while the collision alert is up, so "Change Shortcut" resumes
    /// the slot the reader was editing instead of appending a new one.
    private enum Target: Equatable {
        case adding
        case replacing(PhantomShortcut)
    }

    @State private var target: Target?
    @State private var isRecording = false
    @State private var collision: ShortcutCollision?
    @State private var monitor: Any?

    private var shortcuts: [PhantomShortcut] { store.shortcuts(for: action) }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                ForEach(shortcuts, id: \.self) { shortcut in
                    chip(shortcut)
                }

                if shortcuts.isEmpty {
                    Text("None")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                addButton

                if !store.isDefault(action) {
                    Button {
                        cancelCapture()
                        store.resetToDefault(action)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to the default shortcut")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                Text(action.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert(
            "Shortcut already in use",
            isPresented: Binding(
                get: { collision != nil },
                set: { if !$0 { collision = nil } }
            )
        ) {
            Button("Change Shortcut") { startCapture(target ?? .adding) }
            Button("Discard", role: .cancel) { cancelCapture() }
        } message: {
            Text(collision?.message ?? "")
        }
        .onDisappear { stopMonitor() }
    }

    private func chip(_ shortcut: PhantomShortcut) -> some View {
        HStack(spacing: 2) {
            Button {
                if isRecording, target == .replacing(shortcut) {
                    cancelCapture()
                } else {
                    startCapture(.replacing(shortcut))
                }
            } label: {
                Text(isRecording && target == .replacing(shortcut) ? "Press keys…" : shortcut.displayString)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 56)
            }
            .buttonStyle(.bordered)
            .help("Click, then press the key combination to record over this one")

            Button {
                cancelCapture()
                store.remove(shortcut, from: action)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove this shortcut")
        }
    }

    /// Two buttons rather than one whose style changes: `.buttonStyle` takes
    /// one concrete type, so a style picked by a ternary doesn't type-check.
    @ViewBuilder
    private var addButton: some View {
        if isRecording, target == .adding {
            Button {
                cancelCapture()
            } label: {
                Text("Press keys…")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 56)
            }
            .buttonStyle(.bordered)
            .help("Press the key combination to add, or Escape to stop")
        } else {
            Button {
                startCapture(.adding)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add another shortcut for this command")
        }
    }

    private func startCapture(_ target: Target) {
        stopMonitor()
        self.target = target
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
        }
    }

    /// What to do with a key pressed while recording. A bare modifier (⌘ on
    /// its own, ⇧ on its own) is not a shortcut, so it passes through and
    /// recording keeps waiting; any real key ends recording.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let captured = PhantomShortcut(event: event) else { return event }
        /// Escape stops recording instead of being recorded: a shortcut that
        /// cannot be backed out of is a trap, and Escape is where everyone
        /// reaches for that.
        guard captured.key != "\u{1B}" else {
            cancelCapture()
            return nil
        }
        guard let target else { return nil }

        stopMonitor()
        isRecording = false

        let current: PhantomShortcut?
        switch target {
        case .adding: current = nil
        case .replacing(let existing): current = existing
        }

        let collisions = ShortcutCollisionChecker.collisions(
            with: captured,
            for: action,
            excluding: current,
            bindings: store.map,
            menu: NSApp.mainMenu
        )

        if let first = collisions.first {
            collision = first
            return nil
        }

        switch target {
        case .adding: store.add(captured, to: action)
        case .replacing(let existing): store.replace(existing, with: captured, for: action)
        }
        self.target = nil
        return nil
    }

    private func cancelCapture() {
        stopMonitor()
        isRecording = false
        target = nil
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
