import AppKit
import Foundation
@testable import Ghostty
import Testing

/// The filter behind the Keyboard Shortcuts pane's search field.
struct KeyboardShortcutSearchTests {
    @Test func anEmptyQueryKeepsEverything() {
        #expect(KeyboardShortcutSearch.matches(query: "", in: "Save"))
        #expect(KeyboardShortcutSearch.matches(query: "   ", in: "Save"))
    }

    @Test func aQueryMatchesRegardlessOfCaseOrSurroundingSpace() {
        #expect(KeyboardShortcutSearch.matches(query: "SAVE", in: "Save All"))
        #expect(KeyboardShortcutSearch.matches(query: "  save  ", in: "Save All"))
    }

    /// Every field a row shows counts, which is what lets somebody find
    /// "Go to Definition" by typing the sentence under it or the action
    /// string beside it.
    @Test func anyOfARowsVisibleFieldsCanMatch() {
        #expect(KeyboardShortcutSearch.matches(query: "caret", in: "Rename Symbol", "Renames the symbol under the caret"))
        #expect(KeyboardShortcutSearch.matches(query: "new_split", in: "Split Right", "new_split:right"))
    }

    @Test func aQueryNothingCarriesMatchesNothing() {
        #expect(!KeyboardShortcutSearch.matches(query: "zzz", in: "Save", "Writes the focused file to disk"))
    }
}

/// The read-only **Fixed** section, and the table it is drawn from.
@MainActor
struct FixedShortcutSectionTests {
    /// The pane lists the two groups separately and the checker refuses
    /// recordings against the whole table. One of them assembling the other
    /// is what keeps a key from being listed but not guarded, or guarded but
    /// never shown.
    @Test func theTwoGroupsAreExactlyTheFixedTable() {
        let assembled = ShortcutCollisionChecker.paneShortcuts
            + ShortcutCollisionChecker.fileExplorerShortcuts

        #expect(assembled.map(\.owner) == ShortcutCollisionChecker.fixedShortcuts.map(\.owner))
        #expect(assembled.map(\.shortcut) == ShortcutCollisionChecker.fixedShortcuts.map(\.shortcut))
    }

    @Test func everyPaneChordIsOnOptionCommand() {
        for entry in ShortcutCollisionChecker.paneShortcuts {
            #expect(entry.shortcut.modifiers == [.command, .option], "\(entry.owner)")
        }
    }

    /// The explorer dispatches on unmodified keys, which is the reason they
    /// need naming at all: nothing else in the app would report them taken.
    @Test func everyExplorerKeyIsUnmodified() {
        for entry in ShortcutCollisionChecker.fileExplorerShortcuts {
            #expect(entry.shortcut.modifiers.isEmpty, "\(entry.owner)")
        }
    }

    /// Return, Delete and Space report characters that draw as *nothing*, so
    /// listing them in Settings — and naming them in the collision warning —
    /// produced a blank where a shortcut belongs.
    @Test func noFixedShortcutDrawsAsBlank() {
        for entry in ShortcutCollisionChecker.fixedShortcuts {
            let label = entry.shortcut.displayString.trimmingCharacters(in: .whitespacesAndNewlines)
            let control = label.rangeOfCharacter(from: .controlCharacters) != nil
            #expect(!label.isEmpty, "\(entry.owner) has nothing to show")
            #expect(!control, "\(entry.owner) draws a control character")
        }
    }

    @Test func theExplorersOwnKeysAreNamedRatherThanLeftAsCodepoints() {
        #expect(PhantomShortcut(key: "\r", modifiers: []).displayString == "⏎")
        #expect(PhantomShortcut(key: "\u{7f}", modifiers: []).displayString == "⌫")
        #expect(PhantomShortcut(key: " ", modifiers: []).displayString == "␣")
    }

    @Test func noTwoFixedEntriesClaimTheSameKeys() {
        var seen: [PhantomShortcut: String] = [:]
        for entry in ShortcutCollisionChecker.fixedShortcuts {
            if let other = seen[entry.shortcut] {
                Issue.record("\(entry.shortcut.displayString): \(entry.owner) and \(other)")
            }
            seen[entry.shortcut] = entry.owner
        }
    }

    /// The owner is what the pane keys its rows on, so two of them alike
    /// would drop a row rather than draw it twice.
    @Test func noTwoFixedEntriesShareAnOwner() {
        var seen: Set<String> = []
        for entry in ShortcutCollisionChecker.fixedShortcuts {
            #expect(seen.insert(entry.owner).inserted, "\(entry.owner)")
        }
    }
}

/// The read-only **From Your Config** section: the table of Ghostty actions
/// the pane is willing to name, and how it narrows to what is bound.
struct GhosttyConfigShortcutCatalogTests {
    @Test func everyEntryIsNamedAndCarriesAnAction() {
        for entry in GhosttyConfigShortcutCatalog.allEntries {
            #expect(!entry.title.isEmpty, "\(entry.action)")
            #expect(!entry.action.isEmpty, "\(entry.title)")
        }
    }

    /// The action string is handed to `ghostty_config_trigger` verbatim, so a
    /// stray space or capital is a row that silently never appears.
    @Test func everyActionIsSpelledTheWayTheConfigFileSpellsIt() {
        for entry in GhosttyConfigShortcutCatalog.allEntries {
            let spaced = entry.action.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            #expect(entry.action == entry.action.lowercased(), "\(entry.action)")
            #expect(!spaced, "\(entry.action) carries whitespace")
        }
    }

    @Test func noActionIsListedTwice() {
        var seen: Set<String> = []
        for entry in GhosttyConfigShortcutCatalog.allEntries {
            #expect(seen.insert(entry.action).inserted, "\(entry.action)")
        }
    }

    /// The point of the section. Every one of these is bound out of the box
    /// and has no menu item, so before this the app never admitted it existed.
    @Test func theCatalogReachesPastTheMenuBar() {
        let actions = Set(GhosttyConfigShortcutCatalog.allEntries.map(\.action))

        #expect(actions.contains("clear_screen"))
        #expect(actions.contains("goto_tab:1"))
        #expect(actions.contains("jump_to_prompt:-1"))
        #expect(actions.contains("scroll_page_up"))
    }

    @Test func anUnboundActionDrawsNoRowAndAnEmptyGroupNoHeader() {
        let onlyQuit = GhosttyConfigShortcutCatalog.resolved(
            keys: { $0 == "quit" ? "⌘Q" : nil })

        #expect(onlyQuit.map(\.title) == ["Application"])
        #expect(onlyQuit.first?.bindings.map(\.entry.action) == ["quit"])
        #expect(onlyQuit.first?.bindings.first?.keys == "⌘Q")
    }

    @Test func theSearchFilterNarrowsGroupsBeforeTheyAreDrawn() {
        let everythingBound = GhosttyConfigShortcutCatalog.resolved(
            keys: { _ in "⌘X" },
            include: { KeyboardShortcutSearch.matches(query: "split", in: $0.title, $0.action) })

        #expect(everythingBound.map(\.title) == ["Splits"])
        #expect(everythingBound.first?.bindings.isEmpty == false)
    }

    @Test func nothingBoundMeansNoSectionAtAll() {
        #expect(GhosttyConfigShortcutCatalog.resolved(keys: { _ in nil }).isEmpty)
    }
}

/// The catalog against a real configuration, because the part that can go
/// wrong silently is the spelling.
///
/// An action string is handed to `ghostty_config_trigger` verbatim; get one
/// character wrong — `resize_split:up` for `resize_split:up,10` — and the
/// lookup answers nil, the row never draws, and every test above still
/// passes. A `TemporaryConfig` is a real load of Ghostty's own defaults with
/// nothing of this machine's in it, so these are stable answers.
struct CatalogAgainstGhosttyDefaultsTests {
    @Test func theSectionIsWorthOpeningOnADefaultConfiguration() throws {
        let config = try TemporaryConfig("")
        let groups = GhosttyConfigShortcutCatalog.resolved(in: config)
        let rows = groups.reduce(0) { $0 + $1.bindings.count }

        /// Fifty-one rows in six groups as this is written. The floor is well
        /// under that so an upstream rebinding cannot fail the suite, and well
        /// over zero so a catalog that stopped resolving does.
        #expect(rows >= 40, "only \(rows) of the catalog resolved")
        #expect(groups.count >= 5, "\(groups.map(\.title))")
    }

    /// The parameterized ones, which are where a wrong spelling hides.
    @Test func theActionStringsWithArgumentsResolve() throws {
        let config = try TemporaryConfig("")

        for action in [
            "goto_tab:1", "resize_split:up,10", "jump_to_prompt:-1",
            "increase_font_size:1", "inspector:toggle", "new_split:right",
            "goto_split:previous", "write_screen_file:paste", "navigate_search:next",
        ] {
            let entry = GhosttyConfigShortcutCatalog.allEntries.first { $0.action == action }
            #expect(entry != nil, "\(action) left the catalog")
        }

        #expect(config.keyboardShortcut(for: "goto_tab:1")?.description == "⌘1")
        #expect(config.keyboardShortcut(for: "new_split:right")?.description == "⌘D")
        #expect(config.keyboardShortcut(for: "resize_split:up,10") != nil)
        #expect(config.keyboardShortcut(for: "jump_to_prompt:-1") != nil)
        #expect(config.keyboardShortcut(for: "increase_font_size:1") != nil)
        #expect(config.keyboardShortcut(for: "inspector:toggle") != nil)
        #expect(config.keyboardShortcut(for: "write_screen_file:paste") != nil)
    }

    /// What the section's footer says, pinned. Ghostty keeps a *performable*
    /// binding out of the reverse map on purpose, so the default ⌘K on
    /// Clear Screen cannot be read back however firmly it is bound.
    @Test func aPerformableDefaultCannotBeReadBack() throws {
        let config = try TemporaryConfig("")
        #expect(config.keyboardShortcut(for: "clear_screen") == nil)
    }

    /// And it is performability, not the action, that hides it: bound by hand
    /// the same command reads back and the row appears.
    @Test func theSameActionBoundByHandDoesAppear() throws {
        let config = try TemporaryConfig("keybind = ctrl+super+k=clear_screen")
        let terminal = GhosttyConfigShortcutCatalog.resolved(in: config)
            .first { $0.title == "Terminal" }

        #expect(config.keyboardShortcut(for: "clear_screen")?.description == "⌃⌘K")
        #expect(terminal?.bindings.contains { $0.entry.action == "clear_screen" } == true)
    }
}
