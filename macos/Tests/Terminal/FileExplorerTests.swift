import Foundation
@testable import Ghostty
import SwiftUI
import Testing

/// The file explorer's directory listing: ordering and hidden-file
/// handling, against a real temp directory tree.
struct FileExplorerTests {
    /// Resolved through the POSIX `realpath` rather than
    /// `URL.resolvingSymlinksInPath()`, which leaves the `/var` →
    /// `/private/var` symlink that temp directories sit behind alone —
    /// `FileManager` returns the resolved form, so constructed expectations
    /// would never match. Same reason `SidebarGroupTests` does this.
    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    private func makeFile(_ base: URL, _ name: String) throws {
        try Data().write(to: base.appendingPathComponent(name))
    }

    private func makeDir(_ base: URL, _ name: String) throws {
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func node(_ name: String, isDirectory: Bool) -> FileNode {
        FileNode(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: isDirectory
        )
    }

    // MARK: Sorting

    @Test func directoriesSortBeforeFiles() {
        let sorted = FileExplorerModel.sorted([
            node("zebra", isDirectory: true),
            node("alpha", isDirectory: false),
        ])
        #expect(sorted.map(\.name) == ["zebra", "alpha"])
    }

    /// Lowercase and uppercase names interleaving by ASCII value is the
    /// classic wrong-looking listing — `Zoo` must not sort before `apple`.
    @Test func namesSortCaseInsensitively() {
        let sorted = FileExplorerModel.sorted([
            node("Zoo", isDirectory: false),
            node("apple", isDirectory: false),
            node("Banana", isDirectory: false),
        ])
        #expect(sorted.map(\.name) == ["apple", "Banana", "Zoo"])
    }

    @Test func sortingIsStableAcrossBothRules() {
        let sorted = FileExplorerModel.sorted([
            node("src", isDirectory: true),
            node("README.md", isDirectory: false),
            node("Assets", isDirectory: true),
            node("build.zig", isDirectory: false),
        ])
        #expect(sorted.map(\.name) == ["Assets", "src", "build.zig", "README.md"])
    }

    /// Dot-names lead their own group rather than scattering through it.
    /// Arriving interleaved — `.eslintrc` between `dist` and `foo` — is the
    /// failure this pins down, and it is the one a localized comparison
    /// would produce if it treated the dot as punctuation to skip over.
    @Test func dotNamesLeadTheirGroup() {
        let sorted = FileExplorerModel.sorted([
            node("src", isDirectory: true),
            node("README.md", isDirectory: false),
            node(".github", isDirectory: true),
            node(".env", isDirectory: false),
            node("build.zig", isDirectory: false),
            node(".claude", isDirectory: true),
        ])
        #expect(sorted.map(\.name) == [
            ".claude", ".github", "src",
            ".env", "build.zig", "README.md",
        ])
    }

    // MARK: Scanning

    @Test func scanListsDirectoriesFirstThenFiles() throws {
        let base = try tempDirectory()
        try makeDir(base, "src")
        try makeFile(base, "README.md")
        try makeDir(base, "macos")

        let scanned = FileExplorerModel.scan(directory: base, showHidden: false)
        #expect(scanned.map(\.name) == ["macos", "src", "README.md"])
        #expect(scanned.first?.isDirectory == true)
    }

    @Test func scanSkipsDotNamesWhenHiddenFilesAreOff() throws {
        let base = try tempDirectory()
        try makeFile(base, "visible.txt")
        try makeFile(base, ".hidden")
        try makeDir(base, ".git")

        let scanned = FileExplorerModel.scan(directory: base, showHidden: false)
        #expect(scanned.map(\.name) == ["visible.txt"])
    }

    @Test func scanIncludesHiddenEntriesWhenAsked() throws {
        let base = try tempDirectory()
        try makeFile(base, "visible.txt")
        try makeFile(base, ".hidden")

        let scanned = FileExplorerModel.scan(directory: base, showHidden: true)
        #expect(Set(scanned.map(\.name)) == [".hidden", "visible.txt"])
    }

    /// A folder the user can't read is a normal thing to scroll past; it
    /// must not throw or blank the tree.
    @Test func scanningSomethingUnreadableYieldsAnEmptyList() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)", isDirectory: true)
        #expect(FileExplorerModel.scan(directory: missing, showHidden: false).isEmpty)
    }

    @Test func scanMarksDirectoriesCorrectly() throws {
        let base = try tempDirectory()
        try makeDir(base, "folder")
        try makeFile(base, "file.txt")

        let scanned = FileExplorerModel.scan(directory: base, showHidden: false)
        let byName = Dictionary(uniqueKeysWithValues: scanned.map { ($0.name, $0.isDirectory) })
        #expect(byName["folder"] == true)
        #expect(byName["file.txt"] == false)
    }

    // MARK: Hidden files

    /// The toggle's stored value can be absent, and absent has to mean
    /// *show*: `.github`, `.env` and `.gitignore` are half of what a repo
    /// gets opened to edit. Reading it as a plain bool answers false for a
    /// key nobody ever wrote, which is what hid them.
    @Test func dotNamesShowUntilTheReaderTurnsThemOff() {
        #expect(FileExplorerModel.showHidden(stored: nil) == true)
        #expect(FileExplorerModel.showHidden(stored: false) == false)
        #expect(FileExplorerModel.showHidden(stored: true) == true)
    }

    /// A value of the wrong type is somebody else's `defaults write`, not a
    /// choice this app recorded — it takes the default rather than false.
    @Test func anUnreadableStoredValueTakesTheDefault() {
        #expect(FileExplorerModel.showHidden(stored: "yes") == true)
    }

    /// Dot-directories have to arrive as directories, not as files that
    /// happen to be named oddly — `.github` is meant to expand.
    @Test func dotDirectoriesAreListedAsDirectories() throws {
        let base = try tempDirectory()
        try makeDir(base, ".github")
        try makeFile(base, ".gitignore")
        try makeFile(base, "README.md")

        let scanned = FileExplorerModel.scan(directory: base, showHidden: true)
        #expect(scanned.map(\.name) == [".github", ".gitignore", "README.md"])
        #expect(scanned.first?.isDirectory == true)
    }

    /// `.DS_Store` is rewritten every time a Finder window is scrolled. It
    /// is noise on screen and it would wake the directory watcher for
    /// nothing, so showing hidden files must not bring it along.
    @Test func macOSBookkeepingIsNeverListed() throws {
        let base = try tempDirectory()
        try makeFile(base, ".DS_Store")
        try makeFile(base, ".localized")
        try makeFile(base, ".gitignore")

        #expect(FileExplorerModel.scan(directory: base, showHidden: true).map(\.name) == [".gitignore"])
        #expect(FileExplorerModel.scan(directory: base, showHidden: false).isEmpty)
    }

    /// macOS has a second, invisible notion of hidden: the resource value
    /// Finder sets on a file marked invisible, which is how the `Icon\r`
    /// behind a custom folder icon stays out of sight. The toggle speaks
    /// for the dot prefix only — those stay hidden either way.
    @Test func finderHiddenEntriesWithoutADotStayHidden() throws {
        let base = try tempDirectory()
        try makeFile(base, "invisible.txt")
        try makeFile(base, "visible.txt")
        try makeFile(base, ".gitignore")

        var values = URLResourceValues()
        values.isHidden = true
        var marked = base.appendingPathComponent("invisible.txt")
        try marked.setResourceValues(values)

        let scanned = FileExplorerModel.scan(directory: base, showHidden: true)
        #expect(scanned.map(\.name) == [".gitignore", "visible.txt"])
    }

    // MARK: Dot-name icons

    private func symbolName(_ icon: FileIcon) -> String? {
        guard case .symbol(let name, _) = icon else { return nil }
        return name
    }

    /// A dot-name has no extension in the sense the icon tables are keyed
    /// on — `.eslintrc` splits into one candidate nobody lists — so each
    /// one either has a name entry or draws the blank page. Now that they
    /// are on screen, the common ones are worth pinning.
    @MainActor
    @Test func dotNamesResolveToSomethingBetterThanABlankPage() {
        #expect(symbolName(FileIconProvider.symbolFallback(forFile: ".gitignore"))
            == "arrow.triangle.branch")
        #expect(symbolName(FileIconProvider.symbolFallback(forFile: ".env"))
            == "list.bullet.rectangle")
        #expect(symbolName(FileIconProvider.symbolFallback(forFile: ".eslintrc"))
            == "list.bullet.rectangle")
        #expect(symbolName(FileIconProvider.symbolFallback(forFile: ".zshrc")) == "terminal")
    }

    /// The tables are keyed lowercase and the lookup folds the name, so a
    /// dot-name is not case-sensitive by accident.
    @MainActor
    @Test func aDotNameResolvesRegardlessOfCase() {
        #expect(symbolName(FileIconProvider.symbolFallback(forFile: ".GitIgnore"))
            == "arrow.triangle.branch")
    }

    /// An unknown dot-name still gets the ordinary document icon rather
    /// than nothing at all.
    @MainActor
    @Test func anUnknownDotNameFallsBackToADocument() {
        #expect(symbolName(FileIconProvider.symbolFallback(forFile: ".somethingnobodyhas")) == "doc")
    }

    // MARK: Shell quoting

    /// The explorer builds a shell command from a path it did not choose.
    /// Spaces and quotes in Mac filenames are ordinary, and unquoted they
    /// would re-split into a command that opens something else entirely.
    @Test func pathsAreQuotedForTheShell() {
        #expect(FileOpener.shellQuoted("/tmp/plain.txt") == "'/tmp/plain.txt'")
        #expect(FileOpener.shellQuoted("/tmp/with space.txt") == "'/tmp/with space.txt'")
        #expect(FileOpener.shellQuoted("/tmp/$HOME.txt") == "'/tmp/$HOME.txt'")
    }

    @Test func embeddedSingleQuotesAreEscaped() {
        #expect(FileOpener.shellQuoted("/tmp/it's.txt") == "'/tmp/it'\\''s.txt'")
    }

    // MARK: Terminal command

    /// The editor is left as a shell expression rather than resolved here:
    /// `$EDITOR` comes from the user's shell config, which a GUI app does
    /// not inherit, so only the shell can honour it.
    @Test func terminalCommandKeepsTheEditorExpressionUnresolved() {
        UserDefaults.standard.removeObject(forKey: FileOpener.editorKey)
        let command = FileOpener.terminalCommand(for: URL(fileURLWithPath: "/tmp/a.txt"))
        #expect(command == "\(FileOpener.defaultEditor) '/tmp/a.txt'")
    }

    @Test func terminalCommandQuotesTheArgument() {
        UserDefaults.standard.removeObject(forKey: FileOpener.editorKey)
        let command = FileOpener.terminalCommand(for: URL(fileURLWithPath: "/tmp/two words.txt"))
        #expect(command.hasSuffix(" 'two words.txt'") || command.hasSuffix("'/tmp/two words.txt'"))
    }

    // MARK: Tab naming

    /// The name and extension, never the path. A path deep enough to be
    /// worth reading doesn't fit a 240pt sidebar column, so including it
    /// would truncate away the one part that tells the tabs apart.
    @Test func aTabIsNamedAfterTheFileAlone() {
        let url = URL(fileURLWithPath:
            "/Users/x/Projects/Aurora/aurora-backend/src/main/kotlin/DevAuthz.class")
        #expect(FileOpener.tabName(for: url) == "DevAuthz.class")
    }

    @Test func theExtensionIsKept() {
        #expect(FileOpener.tabName(for: URL(fileURLWithPath: "/a/b/main.vue")) == "main.vue")
        #expect(FileOpener.tabName(for: URL(fileURLWithPath: "/a/b/.gitignore")) == ".gitignore")
        #expect(FileOpener.tabName(for: URL(fileURLWithPath: "/a/b/Makefile")) == "Makefile")
    }

    /// Two files with the same name in different folders produce the same
    /// tab name. That is the accepted cost of dropping the path — worth
    /// pinning down so it reads as a decision rather than an oversight.
    @Test func sameNamedFilesInDifferentFoldersShareATabName() {
        let a = FileOpener.tabName(for: URL(fileURLWithPath: "/one/index.ts"))
        let b = FileOpener.tabName(for: URL(fileURLWithPath: "/two/index.ts"))
        #expect(a == b)
    }

    /// A trailing slash makes `lastPathComponent` unhelpful; falling back
    /// to the path keeps the tab from being renamed to nothing at all.
    @Test func aPathWithNoNameFallsBackRatherThanBlanking() {
        #expect(!FileOpener.tabName(for: URL(fileURLWithPath: "/")).isEmpty)
    }

    // MARK: The keys that act on the selection

    /// The regression itself, spelled as a comparison.
    ///
    /// Settings advertises Delete under **Fixed** as "Move to Trash in the
    /// file explorer" and the key did nothing, because the view matched
    /// presses against `SwiftUI.KeyEquivalent.delete` — U+0008, the ASCII
    /// backspace — while the Delete key reports U+007F. Both spellings are
    /// named here so a future edit cannot quietly swap one for the other.
    @Test func theDeleteKeyIsNotSwiftUIsDeleteKeyEquivalent() {
        #expect(FileExplorerKeyCommand.moveToTrashCharacter == "\u{7F}")
        #expect(KeyEquivalent.delete.character == "\u{8}")
        #expect(FileExplorerKeyCommand.moveToTrashCharacter != KeyEquivalent.delete.character)
    }

    /// And the shortcut Settings promises is the one the tree answers on.
    @MainActor
    @Test func settingsAdvertisesTheKeyTheTreeAnswersOn() {
        let advertised = ShortcutCollisionChecker.fileExplorerShortcuts
            .first { $0.owner == "Move to Trash in the file explorer" }?
            .shortcut
        #expect(advertised?.key == String(FileExplorerKeyCommand.moveToTrashCharacter))
        #expect(advertised?.modifiers.isEmpty == true)
    }

    @Test func deleteWithASelectedRowAsksToTrashIt() {
        let command = FileExplorerKeyCommand.resolve(
            character: FileExplorerKeyCommand.moveToTrashCharacter,
            hasFocus: true,
            isEditing: false,
            selection: "/w/notes.md"
        )
        #expect(command == .moveToTrash(path: "/w/notes.md"))
    }

    @Test func returnWithASelectedRowAsksToRenameIt() {
        let command = FileExplorerKeyCommand.resolve(
            character: FileExplorerKeyCommand.renameCharacter,
            hasFocus: true,
            isEditing: false,
            selection: "/w/notes.md"
        )
        #expect(command == .rename(path: "/w/notes.md"))
    }

    /// Nothing clicked, nothing to trash. The press belongs to whoever else
    /// wants it, so it must not even be reported as handled.
    @Test func deleteWithNoSelectionTrashesNothing() {
        let command = FileExplorerKeyCommand.resolve(
            character: FileExplorerKeyCommand.moveToTrashCharacter,
            hasFocus: true,
            isEditing: false,
            selection: nil
        )
        #expect(command == nil)
    }

    /// The one that matters more than the fix. The explorer shares its window
    /// with a terminal, and a Delete answered while the reader is typing down
    /// there would trash a row they last clicked minutes ago — a worse bug
    /// than the dead key this replaced.
    @Test func deleteWithFocusElsewhereTrashesNothing() {
        let command = FileExplorerKeyCommand.resolve(
            character: FileExplorerKeyCommand.moveToTrashCharacter,
            hasFocus: false,
            isEditing: false,
            selection: "/w/notes.md"
        )
        #expect(command == nil)
    }

    /// A name field is open, so Delete is a backspace inside it.
    @Test func deleteWhileANameIsBeingTypedTrashesNothing() {
        let command = FileExplorerKeyCommand.resolve(
            character: FileExplorerKeyCommand.moveToTrashCharacter,
            hasFocus: true,
            isEditing: true,
            selection: "/w/notes.md"
        )
        #expect(command == nil)
    }

    /// Every other key falls through, which is what leaves the arrows to
    /// navigation and the letters to whatever claims them.
    @Test func anOrdinaryKeyIsNeitherCommand() {
        let command = FileExplorerKeyCommand.resolve(
            character: "n",
            hasFocus: true,
            isEditing: false,
            selection: "/w/notes.md"
        )
        #expect(command == nil)
    }

    // MARK: The row menu

    /// One list, walked by the right-click menu and by the double-click menu
    /// alike — which is the point of it being a list. A file cannot be created
    /// inside, so a file's menu is the folder's minus the two that create, and
    /// minus the separator that separated them.
    @Test func aFolderOffersTheCreateCommandsAndAFileDoesNot() {
        #expect(FileExplorerRowCommand.menu(isDirectory: true) == [
            .command(.newFile),
            .command(.newFolder),
            .separator,
            .command(.rename),
            .command(.delete),
            .separator,
            .command(.revealInFinder),
            .command(.copyPath),
        ])

        #expect(FileExplorerRowCommand.menu(isDirectory: false) == [
            .command(.rename),
            .command(.delete),
            .separator,
            .command(.revealInFinder),
            .command(.copyPath),
        ])
    }

    /// A separator falls where the group changes and nowhere else, so a menu
    /// can never open on a rule with nothing above it.
    @Test func noMenuBeginsOrEndsWithASeparator() {
        for isDirectory in [true, false] {
            let entries = FileExplorerRowCommand.menu(isDirectory: isDirectory)
            #expect(entries.first != .separator)
            #expect(entries.last != .separator)
        }
    }

    // MARK: One click or two

    /// The first click opens the row. It has to: waiting out the double-click
    /// interval before opening a file is the cost this deliberately refuses.
    @Test func aClickWithNothingBeforeItOpensTheRow() {
        #expect(FileExplorerRowClick.resolve(at: 100, previous: nil, interval: 0.5) == .open)
    }

    /// The second click inside the interval asks for the menu — and, just as
    /// importantly, does not open the row a second time. Two
    /// `FileOpener.prompt` calls for one gesture spawn two terminals.
    @Test func aSecondClickInsideTheIntervalAsksForTheMenu() {
        #expect(FileExplorerRowClick.resolve(at: 100.2, previous: 100, interval: 0.5) == .menu)
    }

    @Test func aSecondClickAfterTheIntervalIsAnotherSingleClick() {
        #expect(FileExplorerRowClick.resolve(at: 101, previous: 100, interval: 0.5) == .open)
    }

    /// A clock that ran backwards — a system sleep between two clicks — reads
    /// as a fresh click rather than as a double one, because the safe reading
    /// of an impossible gap is "these are unrelated".
    @Test func aBackwardsClockIsNotADoubleClick() {
        #expect(FileExplorerRowClick.resolve(at: 99, previous: 100, interval: 0.5) == .open)
    }
}
