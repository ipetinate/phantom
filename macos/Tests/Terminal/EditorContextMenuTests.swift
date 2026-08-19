import AppKit
@testable import Ghostty
import Testing

/// What the editor's right-click menu offers.
///
/// The menu used to be `NSTextView`'s own with four items prepended, so it
/// carried spelling, grammar, substitutions, transformations, speech, layout
/// orientation, font and writing direction — a word processor's menu in a code
/// editor, with the useful commands above a wall of submenus. These pin what
/// replaced it, and in particular that nothing from that wall came back.
@MainActor
struct EditorContextMenuTests {
    private func commands(
        definition: Bool = true,
        references: Bool = true,
        rename: Bool = true,
        format: Bool = true
    ) -> [EditorContextCommand] {
        CodeNSTextView.contextMenuCommands(
            hasDefinition: definition,
            hasReferences: references,
            hasRename: rename,
            hasFormat: format
        )
    }

    @Test func aFullyWiredEditorOffersTheLanguageCommandsThenTheClipboard() {
        #expect(commands() == [
            .goToDefinition,
            .findReferences,
            .rename,
            .format,
            .cut,
            .copy,
            .paste,
            .selectAll,
        ])
    }

    /// The clipboard is always there. A file with no language server is the
    /// common case in a scratch buffer, and a menu that came up empty would
    /// read as a broken right-click.
    @Test func anEditorWithNoLanguageServerStillHasAMenu() {
        let bare = commands(definition: false, references: false, rename: false, format: false)

        #expect(bare == [.cut, .copy, .paste, .selectAll])
    }

    /// Each language command appears only when the host wired it, because an
    /// item that does nothing is worse than an absent one.
    @Test func eachLanguageCommandNeedsItsHandler() {
        #expect(!commands(definition: false).contains(.goToDefinition))
        #expect(!commands(references: false).contains(.findReferences))
        #expect(!commands(rename: false).contains(.rename))
        #expect(!commands(format: false).contains(.format))
    }

    /// Groups place the separators, so a group that empties out must not leave
    /// a rule against nothing — which is what a fixed separator index did.
    @Test func groupsAreContiguousSoSeparatorsLandBetweenRuns() {
        for command in [commands(), commands(definition: false, references: false, rename: false, format: false)] {
            let groups = command.map(\.group)
            #expect(groups == groups.sorted(), "groups out of order: \(groups)")

            for (index, group) in groups.enumerated().dropFirst() {
                #expect(group - groups[index - 1] <= 1 || group != groups[index - 1])
            }
        }
    }

    /// The word processor's menu, named so it cannot quietly return. Each of
    /// these was in the stock menu and none belongs in a code editor —
    /// substitutions least of all, since it rewrites quotes in source.
    @Test func nothingFromTheWordProcessorsMenuSurvives() {
        let titles = EditorContextCommand.allCases.map { $0.title.lowercased() }

        for unwanted in [
            "spelling", "grammar", "substitutions", "transformations",
            "speech", "layout orientation", "font", "writing direction",
            "services",
        ] {
            #expect(
                !titles.contains { $0.contains(unwanted) },
                "\(unwanted) is back in the editor's menu"
            )
        }
    }

    /// The clipboard keeps `NSTextView`'s selectors so it keeps `NSTextView`'s
    /// validation — copy greying itself over an empty selection is right, and
    /// judging that here would be judging it worse. The four this app
    /// implements carry no selector; they ride a closure.
    @Test func theClipboardUsesTheStandardSelectorsAndTheRestDoNot() {
        #expect(EditorContextCommand.cut.selector == #selector(NSText.cut(_:)))
        #expect(EditorContextCommand.copy.selector == #selector(NSText.copy(_:)))
        #expect(EditorContextCommand.paste.selector == #selector(NSText.paste(_:)))
        #expect(EditorContextCommand.selectAll.selector == #selector(NSText.selectAll(_:)))

        for command in [EditorContextCommand.goToDefinition, .findReferences, .rename, .format] {
            #expect(command.selector == nil, "\(command.title) should ride a closure")
        }
    }

    /// Format is ⇧⌘F, which was asked for by name, and the menu has to show
    /// the shortcut that actually works — `performKeyEquivalent` claims the
    /// same pair while the editor holds focus.
    @Test func formatShowsTheShortcutThatWorks() {
        #expect(EditorContextCommand.format.key == "f")
        #expect(EditorContextCommand.format.modifiers == [.command, .shift])
    }

    /// Every command has to say something, and a key equivalent without
    /// modifiers would fire on a bare letter.
    @Test func everyCommandIsNamedAndNoKeyIsUnmodified() {
        for command in EditorContextCommand.allCases {
            #expect(!command.title.isEmpty)

            if !command.key.isEmpty {
                #expect(
                    command.modifiers.contains(.command),
                    "\(command.title) binds \(command.key) with no command key"
                )
            }
        }
    }
}
