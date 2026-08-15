import Combine
import Foundation

/// Which app action a configurable shortcut drives.
enum PhantomShortcutAction: CaseIterable, Identifiable {
    case newFile
    case newFolder

    var id: String {
        switch self {
        case .newFile: return "newFile"
        case .newFolder: return "newFolder"
        }
    }

    var title: String {
        switch self {
        case .newFile: return "New File"
        case .newFolder: return "New Folder"
        }
    }

    var detail: String {
        switch self {
        case .newFile: return "Creates a file next to the selection"
        case .newFolder: return "Creates a folder next to the selection"
        }
    }
}

/// The user's configured shortcuts, shared between the settings window
/// that records them and the file explorer that reacts to them.
@MainActor
final class PhantomShortcutStore: ObservableObject {
    static let shared = PhantomShortcutStore()

    static let newFileDefaultsKey = "PhantomShortcutNewFile"
    static let newFolderDefaultsKey = "PhantomShortcutNewFolder"

    /// ⇧⌘N and ⇧⌘M by default: nothing in the app menu or the Ghostty
    /// defaults claims either, and the pair reads as "file / folder".
    static let newFileDefault = PhantomShortcut(key: "n", modifiers: [.command, .shift])
    static let newFolderDefault = PhantomShortcut(key: "m", modifiers: [.command, .shift])

    @Published var newFile: PhantomShortcut {
        didSet {
            guard newFile != oldValue else { return }
            UserDefaults.standard.set(newFile.serialized, forKey: Self.newFileDefaultsKey)
        }
    }

    @Published var newFolder: PhantomShortcut {
        didSet {
            guard newFolder != oldValue else { return }
            UserDefaults.standard.set(newFolder.serialized, forKey: Self.newFolderDefaultsKey)
        }
    }

    /// Internal rather than private so tests can build a fresh store against
    /// a cleared UserDefaults. App code is expected to use `shared`.
    init() {
        newFile = Self.load(key: Self.newFileDefaultsKey, fallback: Self.newFileDefault)
        newFolder = Self.load(key: Self.newFolderDefaultsKey, fallback: Self.newFolderDefault)
    }

    func shortcut(for action: PhantomShortcutAction) -> PhantomShortcut {
        switch action {
        case .newFile: return newFile
        case .newFolder: return newFolder
        }
    }

    func set(_ shortcut: PhantomShortcut, for action: PhantomShortcutAction) {
        switch action {
        case .newFile: newFile = shortcut
        case .newFolder: newFolder = shortcut
        }
    }

    private static func load(key: String, fallback: PhantomShortcut) -> PhantomShortcut {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let shortcut = PhantomShortcut(serialized: raw)
        else { return fallback }
        return shortcut
    }
}
