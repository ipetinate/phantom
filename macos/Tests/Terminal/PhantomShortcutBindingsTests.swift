import AppKit
import Foundation
@testable import Ghostty
import Testing

/// Resolving keys to commands, with no view, no window and no defaults in
/// sight — the part that has to be right for a key press to do anything.
struct PhantomShortcutMapTests {
    private func shortcut(_ key: String, _ modifiers: Set<PhantomShortcutModifier>) -> PhantomShortcut {
        PhantomShortcut(key: key, modifiers: modifiers)
    }

    @Test func everyDefaultResolvesToTheCommandThatDeclaresIt() {
        for action in PhantomShortcutAction.allCases {
            for binding in action.defaultShortcuts {
                #expect(
                    PhantomShortcutMap.defaults.action(for: binding) == action,
                    "\(binding.displayString) should belong to \(action.title)"
                )
            }
        }
    }

    @Test func anUnboundCombinationResolvesToNothing() {
        #expect(PhantomShortcutMap.defaults.action(for: shortcut("q", [.command, .control])) == nil)
    }

    /// The point of the whole change: one command, several ways to reach it.
    @Test func everyShortcutOnACommandsListResolvesToIt() {
        let first = shortcut("f", [.command, .shift])
        let second = shortcut("l", [.command, .shift])
        let map = PhantomShortcutMap([.formatDocument: [first, second]])

        #expect(map.action(for: first) == .formatDocument)
        #expect(map.action(for: second) == .formatDocument)
    }

    /// An empty list is a command that answers to nothing, not a command
    /// that quietly kept its default.
    @Test func aCommandWithAnEmptyListAnswersToNothing() {
        let map = PhantomShortcutMap([.formatDocument: []])
        #expect(map.shortcuts(for: .formatDocument).isEmpty)
        #expect(map.primary(for: .formatDocument) == nil)
        #expect(map.action(for: shortcut("f", [.command, .shift])) == nil)
    }

    @Test func goToDefinitionShipsWithNoShortcutAtAll() {
        #expect(PhantomShortcutMap.defaults.shortcuts(for: .goToDefinition).isEmpty)
    }

    /// A menu item shows exactly one key equivalent, so "the one to show"
    /// has to be a fixed answer rather than whatever comes out of a
    /// dictionary this time.
    @Test func theOneAMenuShowsIsTheFirstInTheListAndStaysThatWay() {
        let first = shortcut("f", [.command, .shift])
        let second = shortcut("l", [.command, .shift])
        let map = PhantomShortcutMap([
            .formatDocument: [first, second],
            .save: [shortcut("s", [.command])],
            .newFile: [shortcut("n", [.command, .shift])],
        ])

        for _ in 0..<50 {
            #expect(map.primary(for: .formatDocument) == first)
        }
    }

    /// Two commands should never claim the same keys — the settings window
    /// refuses it — but a hand-edited plist can, and answering differently
    /// between launches would be worse than answering the first-declared.
    @Test func twoCommandsClaimingTheSameKeysResolveInDeclarationOrder() {
        let clash = shortcut("k", [.command, .control])
        let map = PhantomShortcutMap([.saveAll: [clash], .newFile: [clash]])

        #expect(map.action(for: clash) == .newFile)
    }

    @Test func aKeyPressResolvesRegardlessOfCase() {
        #expect(PhantomShortcutMap.defaults.action(key: "N", modifiers: [.command, .shift]) == .newFile)
        #expect(PhantomShortcutMap.defaults.action(key: "n", modifiers: [.command, .shift]) == .newFile)
    }

    @Test func aKeyPressWithExtraModifiersResolvesToNothing() {
        #expect(PhantomShortcutMap.defaults.action(key: "n", modifiers: [.command, .shift, .option]) == nil)
    }

    /// The old editor answered ⌘S and ⇧⌘S from one branch that asked
    /// whether shift was *among* the modifiers. Matching the whole set is
    /// what keeps two commands on the same letter apart.
    @Test func saveAndSaveAllAreToldApartByTheirModifierSets() {
        #expect(PhantomShortcutMap.defaults.action(key: "s", modifiers: [.command]) == .save)
        #expect(PhantomShortcutMap.defaults.action(key: "s", modifiers: [.command, .shift]) == .saveAll)
    }

    @Test func aKeyEventResolvesToItsCommand() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "F",
            charactersIgnoringModifiers: "F",
            isARepeat: false,
            keyCode: 3
        ))
        #expect(PhantomShortcutMap.defaults.action(matching: event) == .formatDocument)
    }

    @Test func aBareModifierEventResolvesToNothing() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 55
        ))
        #expect(PhantomShortcutMap.defaults.action(matching: event) == nil)
    }

    /// What the editor is handed: its own commands, the explorer's left out,
    /// each command's primary before its extras.
    @Test func editorBindingsCarryOnlyTheEditorsCommands() {
        let bindings = PhantomShortcutMap.defaults.bindings(in: .editor)
        let ids = Set(bindings.map(\.id))

        #expect(!ids.contains(PhantomShortcutAction.newFile.id))
        #expect(!ids.contains(PhantomShortcutAction.newFolder.id))
        #expect(ids.contains(PhantomShortcutAction.formatDocument.id))
        #expect(!ids.contains(PhantomShortcutAction.goToDefinition.id), "no default, so nothing to bind")
    }

    @Test func aCommandsExtraBindingsFollowItsPrimary() {
        let first = shortcut("f", [.command, .shift])
        let second = shortcut("l", [.command, .shift])
        let map = PhantomShortcutMap([.formatDocument: [first, second]])

        let mine = map.bindings(in: .editor).filter { $0.id == PhantomShortcutAction.formatDocument.id }
        #expect(mine.map(\.shortcut) == [first, second])
    }

    @Test func aBindingSpellsItsKeyEquivalentTheWayAppKitWantsIt() {
        let binding = PhantomShortcutBinding(id: "formatDocument", shortcut: shortcut("f", [.command, .shift]))
        #expect(binding.keyEquivalent == "f")
        #expect(binding.modifierFlags == [.command, .shift])
    }

    @Test func explorerBindingsCarryOnlyTheExplorersCommands() {
        let ids = Set(PhantomShortcutMap.defaults.bindings(in: .fileExplorer).map(\.id))
        #expect(ids == [PhantomShortcutAction.newFile.id, PhantomShortcutAction.newFolder.id])
    }
}

/// The one place the same default is written down twice.
///
/// The engine carries its own table so an editor with no host wiring still
/// draws a usable menu, and this app decides what the commands ship bound
/// to. Two sources for one fact is how a menu ends up showing a key that
/// does nothing — so they are held to each other here rather than by
/// remembering.
struct EditorDefaultShortcutAgreementTests {
    @Test func theEnginesMenuTableAgreesWithTheAppsDefaults() throws {
        for command in EditorContextCommand.allCases {
            guard let id = command.actionID else { continue }
            let action = try #require(
                PhantomShortcutAction(rawValue: id),
                "\(id) is not a configurable command"
            )
            let primary = PhantomShortcutMap.defaults.primary(for: action)

            guard !command.key.isEmpty else {
                #expect(primary == nil, "\(action.title) ships bound to a key the menu cannot show")
                continue
            }

            #expect(primary?.key == command.key, "\(action.title)")
            #expect(primary?.eventModifierFlags == command.modifiers, "\(action.title)")
        }
    }
}

/// The store that persists every command's list, against a defaults domain
/// of its own — a test that wrote the real one would change the machine it
/// ran on.
@MainActor
struct PhantomShortcutStoreTests {
    private func withStore(
        seed: [String: Any] = [:],
        _ body: (PhantomShortcutStore, UserDefaults) throws -> Void
    ) throws {
        let name = "PhantomShortcutStoreTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        for (key, value) in seed {
            defaults.set(value, forKey: key)
        }
        try body(PhantomShortcutStore(defaults: defaults), defaults)
    }

    @Test func everyCommandStartsOnTheDefaultsItDeclares() throws {
        try withStore { store, _ in
            for action in PhantomShortcutAction.allCases {
                #expect(store.shortcuts(for: action) == action.defaultShortcuts)
                #expect(store.isDefault(action))
            }
        }
    }

    @Test func aSecondShortcutJoinsTheFirstAndSurvivesARelaunch() throws {
        try withStore { store, defaults in
            let extra = PhantomShortcut(key: "l", modifiers: [.command, .control])
            #expect(store.add(extra, to: .formatDocument))

            #expect(store.shortcuts(for: .formatDocument) == [
                PhantomShortcut(key: "f", modifiers: [.command, .shift]),
                extra,
            ])

            let relaunched = PhantomShortcutStore(defaults: defaults)
            #expect(relaunched.shortcuts(for: .formatDocument) == store.shortcuts(for: .formatDocument))
        }
    }

    @Test func addingTheSameShortcutTwiceChangesNothing() throws {
        try withStore { store, _ in
            let existing = PhantomShortcut(key: "f", modifiers: [.command, .shift])
            #expect(store.add(existing, to: .formatDocument) == false)
            #expect(store.shortcuts(for: .formatDocument) == [existing])
        }
    }

    /// The state the reader is allowed to be in, and the one an eager
    /// "fall back to the default" would erase on the next launch.
    @Test func aCommandStrippedOfItsLastShortcutStaysStripped() throws {
        try withStore { store, defaults in
            store.remove(PhantomShortcut(key: "n", modifiers: [.command, .shift]), from: .newFile)
            #expect(store.shortcuts(for: .newFile).isEmpty)

            let relaunched = PhantomShortcutStore(defaults: defaults)
            #expect(relaunched.shortcuts(for: .newFile).isEmpty)
            #expect(relaunched.isDefault(.newFile) == false)
        }
    }

    @Test func resetPutsTheDefaultBackAndForgetsTheStoredEntry() throws {
        try withStore { store, defaults in
            store.set([], for: .newFile)
            store.resetToDefault(.newFile)

            #expect(store.shortcuts(for: .newFile) == PhantomShortcutAction.newFile.defaultShortcuts)
            #expect(store.isDefault(.newFile))
            #expect(
                defaults.array(forKey: PhantomShortcutStore.defaultsKey(for: .newFile)) == nil,
                "a stored copy of a default stops being a default the day the default changes"
            )

            let relaunched = PhantomShortcutStore(defaults: defaults)
            #expect(relaunched.shortcuts(for: .newFile) == PhantomShortcutAction.newFile.defaultShortcuts)
        }
    }

    @Test func recordingOverOneEntryLeavesTheOthersWhereTheyWere() throws {
        try withStore { store, _ in
            let first = PhantomShortcut(key: "f", modifiers: [.command, .shift])
            let second = PhantomShortcut(key: "l", modifiers: [.command, .control])
            let replacement = PhantomShortcut(key: "p", modifiers: [.command, .shift, .option])
            store.set([first, second], for: .formatDocument)

            store.replace(first, with: replacement, for: .formatDocument)

            #expect(store.shortcuts(for: .formatDocument) == [replacement, second])
            #expect(store.primary(for: .formatDocument) == replacement)
        }
    }

    @Test func aListWithARepeatedEntryIsStoredOnce() throws {
        try withStore { store, _ in
            let repeated = PhantomShortcut(key: "f", modifiers: [.command, .shift])
            store.set([repeated, repeated], for: .formatDocument)
            #expect(store.shortcuts(for: .formatDocument) == [repeated])
        }
    }

    @Test func theMapMirrorsWhatTheStoreHolds() throws {
        try withStore { store, _ in
            let extra = PhantomShortcut(key: "l", modifiers: [.command, .control])
            store.add(extra, to: .formatDocument)
            #expect(store.map.action(for: extra) == .formatDocument)
        }
    }

    /// A present-but-unreadable entry is a damaged plist, not a decision.
    @Test func anUnreadableStoredEntryFallsBackToTheDefault() throws {
        try withStore(seed: [PhantomShortcutStore.defaultsKey(for: .save): ["not a shortcut"]]) { store, _ in
            #expect(store.shortcuts(for: .save) == PhantomShortcutAction.save.defaultShortcuts)
        }
    }

    @Test func anEmptyStoredEntryIsRespected() throws {
        try withStore(seed: [PhantomShortcutStore.defaultsKey(for: .save): [String]()]) { store, _ in
            #expect(store.shortcuts(for: .save).isEmpty)
        }
    }
}

/// The two keys that were already in people's defaults before a command
/// could hold more than one shortcut.
///
/// Somebody who remapped New File must not have their choice silently
/// replaced by the default the first time they launch a build that stores
/// lists — which is exactly what "just read the new key" would have done.
@MainActor
struct PhantomShortcutMigrationTests {
    private func withDefaults(
        seed: [String: Any],
        _ body: (UserDefaults) throws -> Void
    ) throws {
        let name = "PhantomShortcutMigrationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        for (key, value) in seed {
            defaults.set(value, forKey: key)
        }
        try body(defaults)
    }

    @Test func theOldSingleShortcutKeysAreStillTheOnesWeMigrateFrom() {
        #expect(PhantomShortcutStore.legacyDefaultsKey(for: .newFile) == "PhantomShortcutNewFile")
        #expect(PhantomShortcutStore.legacyDefaultsKey(for: .newFolder) == "PhantomShortcutNewFolder")
        #expect(PhantomShortcutStore.legacyDefaultsKey(for: .save) == nil)
    }

    @Test func aRemappedNewFileSurvivesTheMoveToLists() throws {
        try withDefaults(seed: [
            "PhantomShortcutNewFile": "shift+command+j",
            "PhantomShortcutNewFolder": "control+option+k",
        ]) { defaults in
            let store = PhantomShortcutStore(defaults: defaults)

            #expect(store.shortcuts(for: .newFile) == [
                PhantomShortcut(key: "j", modifiers: [.command, .shift]),
            ])
            #expect(store.shortcuts(for: .newFolder) == [
                PhantomShortcut(key: "k", modifiers: [.control, .option]),
            ])
        }
    }

    @Test func theMigratedValueIsWrittenUnderTheNewKeyAndTheOldOneDropped() throws {
        try withDefaults(seed: ["PhantomShortcutNewFile": "shift+command+j"]) { defaults in
            _ = PhantomShortcutStore(defaults: defaults)

            #expect(
                defaults.array(forKey: PhantomShortcutStore.defaultsKey(for: .newFile)) as? [String]
                    == ["shift+command+j"]
            )
            #expect(
                defaults.string(forKey: "PhantomShortcutNewFile") == nil,
                "left behind, it is a second source of truth for a list the reader may since have emptied"
            )
        }
    }

    /// Migration is a one-time read of a key that no longer exists once a
    /// list has been written, so a list must always win.
    @Test func aStoredListWinsOverTheOldKey() throws {
        try withDefaults(seed: [
            "PhantomShortcutNewFile": "shift+command+j",
            PhantomShortcutStore.defaultsKey(for: .newFile): ["control+command+u"],
        ]) { defaults in
            let store = PhantomShortcutStore(defaults: defaults)
            #expect(store.shortcuts(for: .newFile) == [
                PhantomShortcut(key: "u", modifiers: [.command, .control]),
            ])
        }
    }

    @Test func anEmptiedListIsNotUndoneByTheOldKey() throws {
        try withDefaults(seed: [
            "PhantomShortcutNewFile": "shift+command+j",
            PhantomShortcutStore.defaultsKey(for: .newFile): [String](),
        ]) { defaults in
            #expect(PhantomShortcutStore(defaults: defaults).shortcuts(for: .newFile).isEmpty)
        }
    }

    @Test func anUnreadableOldValueFallsBackToTheDefault() throws {
        try withDefaults(seed: ["PhantomShortcutNewFile": "hyper+j"]) { defaults in
            let store = PhantomShortcutStore(defaults: defaults)
            #expect(store.shortcuts(for: .newFile) == PhantomShortcutAction.newFile.defaultShortcuts)
            #expect(defaults.string(forKey: "PhantomShortcutNewFile") == nil)
        }
    }
}
