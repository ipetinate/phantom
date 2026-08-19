import Combine
import Foundation

/// The user's configured shortcuts, shared between the settings window that
/// records them and the surfaces that answer to them.
///
/// One dictionary keyed by command, not a property per command. The shape
/// before this held `newFile` and `newFolder` as two `@Published` properties
/// with a defaults key and a `switch` arm each, which meant every new
/// command cost four edits in three places — and it is why the editor's own
/// keys were hard-coded instead of configurable. Keyed by command, adding
/// one is a case in `PhantomShortcutAction` and nothing here.
///
/// The value is a *list*, because one command may answer to several
/// combinations. Order inside it means nothing except which one a menu
/// shows — see `PhantomShortcutMap.primary(for:)`.
@MainActor
final class PhantomShortcutStore: ObservableObject {
    static let shared = PhantomShortcutStore()

    /// Where one command's list is persisted. The command's id is part of
    /// the key, so a new command needs no new constant.
    static func defaultsKey(for action: PhantomShortcutAction) -> String {
        "PhantomShortcuts." + action.id
    }

    /// The keys written by the version that stored a single shortcut per
    /// command as one string.
    ///
    /// Only two ever existed, and somebody who remapped New File to their
    /// own combination must not have it quietly replaced by the default the
    /// first time they launch a build that stores lists — so the old value
    /// is read once, rewritten as a one-element list, and the old key is
    /// dropped. Dropping it matters: left behind, it would be a second
    /// source of truth for a command whose list the reader may since have
    /// emptied on purpose.
    static func legacyDefaultsKey(for action: PhantomShortcutAction) -> String? {
        switch action {
        case .newFile: return "PhantomShortcutNewFile"
        case .newFolder: return "PhantomShortcutNewFolder"
        default: return nil
        }
    }

    @Published private(set) var bindings: [PhantomShortcutAction: [PhantomShortcut]] = [:]

    private let defaults: UserDefaults

    /// `defaults` is injected so tests can run against a suite of their own.
    /// App code is expected to use `shared`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for action in PhantomShortcutAction.allCases {
            bindings[action] = Self.load(action, from: defaults)
        }
    }

    /// The resolved value to hand to anything that only needs to *answer* to
    /// keys — the editor engine among them, which must not know this type
    /// exists.
    var map: PhantomShortcutMap { PhantomShortcutMap(bindings) }

    func shortcuts(for action: PhantomShortcutAction) -> [PhantomShortcut] {
        bindings[action] ?? []
    }

    func primary(for action: PhantomShortcutAction) -> PhantomShortcut? {
        shortcuts(for: action).first
    }

    /// Whether the command still answers to exactly what it shipped with —
    /// what decides if "reset" is offered at all.
    func isDefault(_ action: PhantomShortcutAction) -> Bool {
        shortcuts(for: action) == action.defaultShortcuts
    }

    /// Gives the command one more combination. False when it already had it,
    /// which is a no-op rather than a second identical entry.
    @discardableResult
    func add(_ shortcut: PhantomShortcut, to action: PhantomShortcutAction) -> Bool {
        var list = shortcuts(for: action)
        guard !list.contains(shortcut) else { return false }
        list.append(shortcut)
        set(list, for: action)
        return true
    }

    func remove(_ shortcut: PhantomShortcut, from action: PhantomShortcutAction) {
        var list = shortcuts(for: action)
        guard let index = list.firstIndex(of: shortcut) else { return }
        list.remove(at: index)
        set(list, for: action)
    }

    /// Re-records one entry in place, so a command's other shortcuts keep
    /// their positions — and so the menu's key equivalent doesn't jump to a
    /// different one because an edit was a remove followed by an append.
    func replace(
        _ shortcut: PhantomShortcut,
        with replacement: PhantomShortcut,
        for action: PhantomShortcutAction
    ) {
        var list = shortcuts(for: action)
        guard let index = list.firstIndex(of: shortcut) else { return }
        list[index] = replacement
        set(list, for: action)
    }

    /// The whole list at once. An empty one is written as an empty one: a
    /// command the reader stripped of every shortcut stays stripped, and is
    /// not quietly handed its default back on the next launch.
    func set(_ shortcuts: [PhantomShortcut], for action: PhantomShortcutAction) {
        let deduplicated = Self.deduplicated(shortcuts)
        guard deduplicated != bindings[action] else { return }
        bindings[action] = deduplicated
        defaults.set(deduplicated.map(\.serialized), forKey: Self.defaultsKey(for: action))
    }

    /// Puts back what the command shipped with — the only thing that ever
    /// re-adds a default, which is why emptying a list can be trusted.
    ///
    /// Removes the stored entry rather than writing today's defaults into
    /// it: a copy of a default stops being a default the day the default
    /// changes, and someone who pressed "reset" was asking to follow the
    /// app, not to freeze it.
    func resetToDefault(_ action: PhantomShortcutAction) {
        defaults.removeObject(forKey: Self.defaultsKey(for: action))
        if let legacy = Self.legacyDefaultsKey(for: action) {
            defaults.removeObject(forKey: legacy)
        }
        bindings[action] = action.defaultShortcuts
    }

    private static func load(
        _ action: PhantomShortcutAction,
        from defaults: UserDefaults
    ) -> [PhantomShortcut] {
        if let raw = defaults.array(forKey: defaultsKey(for: action)) as? [String] {
            /// An entry that is present and empty is the reader's decision.
            /// An entry that is present and unreadable is a damaged plist,
            /// and falling back to the default beats leaving the command
            /// dead with no way to notice from the outside.
            guard !raw.isEmpty else { return [] }
            let parsed = deduplicated(raw.compactMap(PhantomShortcut.init(serialized:)))
            return parsed.isEmpty ? action.defaultShortcuts : parsed
        }

        if let legacy = legacyDefaultsKey(for: action),
           let raw = defaults.string(forKey: legacy) {
            defaults.removeObject(forKey: legacy)
            if let shortcut = PhantomShortcut(serialized: raw) {
                defaults.set([shortcut.serialized], forKey: defaultsKey(for: action))
                return [shortcut]
            }
        }

        return action.defaultShortcuts
    }

    /// First occurrence wins, order otherwise preserved — a duplicate is a
    /// no-op, and dropping the *later* copy is what keeps the primary put.
    private static func deduplicated(_ shortcuts: [PhantomShortcut]) -> [PhantomShortcut] {
        var seen: Set<PhantomShortcut> = []
        return shortcuts.filter { seen.insert($0).inserted }
    }
}
