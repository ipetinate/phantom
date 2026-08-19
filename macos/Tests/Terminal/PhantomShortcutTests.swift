import AppKit
import Foundation
@testable import Ghostty
import SwiftUI
import Testing

/// The configurable shortcut value type: what it reads from a key event,
/// how it spells and serializes itself, and how it matches presses.
struct PhantomShortcutTests {
    private func shortcut(_ key: String, _ modifiers: Set<PhantomShortcutModifier>) -> PhantomShortcut {
        PhantomShortcut(key: key, modifiers: modifiers)
    }

    @Test func lowercasesItsKey() {
        #expect(shortcut("N", [.command, .shift]).key == "n")
    }

    @Test func displayStringSpellsModifiersInMacOrder() {
        #expect(shortcut("n", [.command, .shift]).displayString == "⇧⌘N")
        #expect(shortcut("f", [.command, .option]).displayString == "⌥⌘F")
        #expect(shortcut("g", [.command, .control]).displayString == "⌃⌘G")
    }

    @Test func aShortcutWithNoModifiersShowsJustTheKey() {
        #expect(shortcut("z", []).displayString == "Z")
    }

    @Test func serializationRoundTrips() {
        let original = shortcut("n", [.command, .shift])
        #expect(original.serialized == "shift+command+n")
        #expect(PhantomShortcut(serialized: original.serialized) == original)
    }

    @Test func serializationWithoutModifiersIsJustTheKey() {
        #expect(shortcut("z", []).serialized == "z")
    }

    @Test func aSerializedStringWithABadModifierRefuses() {
        #expect(PhantomShortcut(serialized: "super+n") == nil)
        #expect(PhantomShortcut(serialized: "") == nil)
    }

    @Test func matchingIgnoresKeyCase() {
        let target = shortcut("n", [.command, .shift])
        #expect(target.matches(modifiers: [.command, .shift], key: "n"))
        #expect(target.matches(modifiers: [.command, .shift], key: "N"))
    }

    @Test func matchingRequiresTheSameModifierSet() {
        let target = shortcut("n", [.command, .shift])
        #expect(!target.matches(modifiers: [.command], key: "n"))
        #expect(!target.matches(modifiers: [.command, .shift, .option], key: "n"))
    }

    @Test func readingARegularKeyEvent() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "N",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        ))
        #expect(PhantomShortcut(event: event) == shortcut("n", [.command, .shift]))
    }

    @Test func aModifierAloneIsNotAShortcut() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 56
        ))
        #expect(PhantomShortcut(event: event) == nil)
    }

    @Test func modifiersFromAPressIgnoreCapsLockAndFunction() {
        let flags: EventModifiers = [.command, .shift, .capsLock]
        let modifiers = PhantomShortcut.modifiers(from: flags)
        #expect(modifiers == [.command, .shift])
    }
}

/// Whether a proposed shortcut is already taken — by a menu item, by one of
/// the fixed pane actions, by another command, or by the same command twice.
@MainActor
struct ShortcutCollisionCheckerTests {
    private func menu(_ items: [(title: String, key: String, flags: NSEvent.ModifierFlags)]) -> NSMenu {
        let menu = NSMenu(title: "Root")
        for item in items {
            let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: item.key)
            entry.keyEquivalentModifierMask = item.flags
            menu.addItem(entry)
        }
        return menu
    }

    private func map(_ bindings: [PhantomShortcutAction: [PhantomShortcut]]) -> PhantomShortcutMap {
        PhantomShortcutMap(bindings)
    }

    @Test func anUnclaimedShortcutCollidesWithNothing() {
        let menu = menu([("New Window", "n", [.command])])
        let candidate = PhantomShortcut(key: "n", modifiers: [.command, .shift])
        #expect(ShortcutCollisionChecker.collisions(
            with: candidate, for: .newFile, excluding: nil, bindings: map([:]), menu: menu
        ).isEmpty)
    }

    @Test func aMenuKeyEquivalentCollides() {
        let menu = menu([("New Window", "n", [.command])])
        let candidate = PhantomShortcut(key: "n", modifiers: [.command])
        let collisions = ShortcutCollisionChecker.collisions(
            with: candidate, for: .newFile, excluding: nil, bindings: map([:]), menu: menu
        )
        #expect(collisions == [
            ShortcutCollision(owner: "New Window", shortcut: candidate, source: .menu),
        ])
    }

    /// Re-recording the shortcut that is already assigned to this action is
    /// the same gesture again — it must not warn about itself.
    @Test func theCurrentShortcutIsExcluded() {
        let menu = menu([("New Window", "n", [.command])])
        let current = PhantomShortcut(key: "n", modifiers: [.command])
        #expect(ShortcutCollisionChecker.collisions(
            with: current,
            for: .newFile,
            excluding: current,
            bindings: map([.newFile: [current]]),
            menu: menu
        ).isEmpty)
    }

    @Test func anotherCommandsShortcutCollides() {
        let taken = PhantomShortcut(key: "n", modifiers: [.command, .shift])
        let collisions = ShortcutCollisionChecker.collisions(
            with: taken,
            for: .newFile,
            excluding: nil,
            bindings: map([.newFolder: [taken]]),
            menu: nil
        )
        #expect(collisions.map(\.owner) == ["New Folder"])
        #expect(collisions.map(\.source) == [.otherCommand])
    }

    /// The same combination twice on one command changes nothing, and the
    /// reader has to be told that rather than shown "already used by Format
    /// Document" while recording for Format Document.
    @Test func theSameCommandsOwnShortcutCollidesAsADuplicate() {
        let taken = PhantomShortcut(key: "f", modifiers: [.command, .shift])
        let collisions = ShortcutCollisionChecker.collisions(
            with: taken,
            for: .formatDocument,
            excluding: nil,
            bindings: map([.formatDocument: [taken]]),
            menu: nil
        )
        #expect(collisions.map(\.source) == [.sameCommand])
        #expect(collisions.first?.message.contains("would change nothing") == true)
    }

    /// A second binding for a command that already has one is the whole
    /// point of the list, so it must not be refused for existing.
    @Test func addingASecondUnclaimedShortcutToACommandIsFine() {
        let existing = PhantomShortcut(key: "f", modifiers: [.command, .shift])
        let candidate = PhantomShortcut(key: "l", modifiers: [.command, .control])
        #expect(ShortcutCollisionChecker.collisions(
            with: candidate,
            for: .formatDocument,
            excluding: nil,
            bindings: map([.formatDocument: [existing]]),
            menu: nil
        ).isEmpty)
    }

    /// Most specific first: the alert leads with the list the reader can fix
    /// without knowing anything about the rest of the app.
    @Test func theDuplicateIsReportedBeforeTheMenu() {
        let taken = PhantomShortcut(key: "n", modifiers: [.command])
        let collisions = ShortcutCollisionChecker.collisions(
            with: taken,
            for: .newFile,
            excluding: nil,
            bindings: map([.newFile: [taken]]),
            menu: menu([("New Window", "n", [.command])])
        )
        #expect(collisions.map(\.source) == [.sameCommand, .menu])
    }

    @Test func fixedPaneShortcutsCollide() {
        let candidate = PhantomShortcut(key: "\\", modifiers: [.command, .option])
        let collisions = ShortcutCollisionChecker.collisions(
            with: candidate, for: .newFile, excluding: nil, bindings: map([:]), menu: nil
        )
        #expect(collisions.map(\.owner).contains("Toggle terminal pane"))
    }

    /// The editor's keys are configurable commands now. Leaving them in the
    /// fixed table as well would make every one of them collide with itself
    /// the moment somebody re-recorded it.
    @Test func theEditorsOwnKeysAreNoLongerFixed() {
        let owners = ShortcutCollisionChecker.fixedShortcuts.map(\.owner)
        #expect(!owners.contains("Format document"))
        #expect(!owners.contains("Rename symbol"))
        #expect(!owners.contains("Find references"))
        #expect(!owners.contains("Search workspace"))
    }

    @Test func submenuItemsAreFound() {
        let menu = NSMenu(title: "Root")
        let submenu = NSMenu(title: "File")
        let entry = NSMenuItem(title: "New File", action: nil, keyEquivalent: "j")
        entry.keyEquivalentModifierMask = [.command, .option]
        submenu.addItem(entry)
        let item = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)

        let candidate = PhantomShortcut(key: "j", modifiers: [.command, .option])
        #expect(ShortcutCollisionChecker.collisions(
            with: candidate, for: .newFile, excluding: nil, bindings: map([:]), menu: menu
        ).map(\.owner) == ["New File"])
    }
}

/// The editor's bookkeeping when a file is renamed or moved inside the app.
struct EditorTabRepathTests {
    @Test func repathKeepsTheTabInPlaceWithItsDirtyDot() {
        var tabs = EditorTabSet()
        ["/a.ts", "/b.ts"].forEach { tabs.open($0) }
        tabs.setDirty(true, for: "/b.ts")

        tabs.repath(from: "/b.ts", to: "/c.ts")

        #expect(tabs.tabs.map(\.id) == ["/a.ts", "/c.ts"])
        #expect(tabs.tabs[1].isDirty)
        #expect(tabs.hasUnsavedChanges)
    }

    @Test func repathMovesTheSelectionWithTheFile() {
        var tabs = EditorTabSet()
        ["/a.ts", "/b.ts"].forEach { tabs.open($0) }
        tabs.select("/b.ts")

        tabs.repath(from: "/b.ts", to: "/c.ts")

        #expect(tabs.selectedPath == "/c.ts")
    }

    @Test func repathOfAnUnselectedFileLeavesTheSelectionAlone() {
        var tabs = EditorTabSet()
        ["/a.ts", "/b.ts"].forEach { tabs.open($0) }
        tabs.select("/a.ts")

        tabs.repath(from: "/b.ts", to: "/c.ts")

        #expect(tabs.selectedPath == "/a.ts")
    }

    @Test func repathToTheSamePathDoesNothing() {
        var tabs = EditorTabSet()
        tabs.open("/a.ts")
        tabs.repath(from: "/a.ts", to: "/a.ts")
        #expect(tabs.tabs.count == 1)
    }

    @Test func repathOfSomethingNotOpenChangesNothing() {
        var tabs = EditorTabSet()
        tabs.open("/a.ts")
        tabs.repath(from: "/nope.ts", to: "/yep.ts")
        #expect(tabs.tabs.map(\.id) == ["/a.ts"])
    }
}

/// The filesystem operations behind rename, move, delete and create,
/// against a real temp directory tree.
struct FileExplorerFilesystemTests {
    /// Resolved through `realpath` so the `/var` → `/private/var` symlink
    /// doesn't make constructed expectations mismatch `FileManager`'s own
    /// answers. Same reason `FileExplorerTests` does this.
    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    private func makeFile(_ base: URL, _ name: String) throws {
        try Data("content".utf8).write(to: base.appendingPathComponent(name))
    }

    private func makeDir(_ base: URL, _ name: String) throws {
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    // MARK: Rename

    @Test func renameMovesTheFileAndKeepsItInItsDirectory() throws {
        let base = try tempDirectory()
        try makeFile(base, "old.txt")

        let result = FileExplorerFilesystem.rename(
            base.appendingPathComponent("old.txt"), to: "new.txt"
        )

        let target = try result.get()
        #expect(target.lastPathComponent == "new.txt")
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("old.txt").path))
    }

    @Test func renameRefusesACollision() throws {
        let base = try tempDirectory()
        try makeFile(base, "a.txt")
        try makeFile(base, "b.txt")

        let result = FileExplorerFilesystem.rename(
            base.appendingPathComponent("a.txt"), to: "b.txt"
        )
        #expect(throws: (any Error).self) { try result.get() }
    }

    @Test func renameRefusesAnEmptyName() throws {
        let base = try tempDirectory()
        try makeFile(base, "a.txt")
        #expect(throws: (any Error).self) {
            try FileExplorerFilesystem.rename(
                base.appendingPathComponent("a.txt"), to: "   "
            ).get()
        }
    }

    @Test func renameTrimsTrailingWhitespace() throws {
        let base = try tempDirectory()
        try makeFile(base, "a.txt")

        let result = FileExplorerFilesystem.rename(
            base.appendingPathComponent("a.txt"), to: "b.txt "
        )
        #expect(try result.get().lastPathComponent == "b.txt")
    }

    @Test func renamingToItselfSucceeds() throws {
        let base = try tempDirectory()
        try makeFile(base, "a.txt")
        let url = base.appendingPathComponent("a.txt")
        #expect(try FileExplorerFilesystem.rename(url, to: "a.txt").get() == url)
    }

    /// Fixing the capitalisation of a name is a rename people do all the
    /// time, and on the default case-insensitive volume the target "already
    /// exists" — it is the same file. The collision check had no way to tell
    /// that from a real clash, so it refused the rename outright.
    @Test func renameCanChangeNothingButTheCase() throws {
        let base = try tempDirectory()
        try makeFile(base, "readme.md")

        let target = try FileExplorerFilesystem.rename(
            base.appendingPathComponent("readme.md"), to: "README.md"
        ).get()

        #expect(target.lastPathComponent == "README.md")
        let listed = try FileManager.default.contentsOfDirectory(atPath: base.path)
        #expect(listed.contains("README.md"))
        #expect(!listed.contains("readme.md"))
    }

    @Test func aFolderCanBeRecasedToo() throws {
        let base = try tempDirectory()
        try makeDir(base, "sources")

        let target = try FileExplorerFilesystem.rename(
            base.appendingPathComponent("sources", isDirectory: true), to: "Sources"
        ).get()

        #expect(target.lastPathComponent == "Sources")
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).contains("Sources"))
    }

    // MARK: Move

    @Test func movePutsTheFileIntoTheFolder() throws {
        let base = try tempDirectory()
        try makeFile(base, "a.txt")
        try makeDir(base, "folder")

        let result = FileExplorerFilesystem.move(
            base.appendingPathComponent("a.txt"),
            into: base.appendingPathComponent("folder", isDirectory: true)
        )

        let target = try result.get()
        #expect(target.path == base.appendingPathComponent("folder/a.txt").path)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func movingAFolderIntoTargetFolderItselfRefuses() throws {
        let base = try tempDirectory()
        try makeDir(base, "a")

        let result = FileExplorerFilesystem.move(
            base.appendingPathComponent("a"),
            into: base.appendingPathComponent("a", isDirectory: true)
        )
        #expect(throws: (any Error).self) { try result.get() }
    }

    @Test func movingAFolderIntoItsOwnChildRefuses() throws {
        let base = try tempDirectory()
        try makeDir(base, "a")
        try makeDir(base, "a/sub")

        let result = FileExplorerFilesystem.move(
            base.appendingPathComponent("a"),
            into: base.appendingPathComponent("a/sub", isDirectory: true)
        )
        #expect(throws: (any Error).self) { try result.get() }
    }

    @Test func moveRefusesANameClash() throws {
        let base = try tempDirectory()
        try makeFile(base, "a.txt")
        try makeDir(base, "folder")
        try makeFile(base, "folder/a.txt")

        let result = FileExplorerFilesystem.move(
            base.appendingPathComponent("a.txt"),
            into: base.appendingPathComponent("folder", isDirectory: true)
        )
        #expect(throws: (any Error).self) { try result.get() }
    }

    // MARK: Create

    @Test func createFileMakesAnEmptyFile() throws {
        let base = try tempDirectory()
        let url = base.appendingPathComponent("notes.txt")
        #expect(try FileExplorerFilesystem.createFile(at: url).get() == url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func createFolderMakesADirectory() throws {
        let base = try tempDirectory()
        let url = base.appendingPathComponent("src", isDirectory: true)
        #expect(try FileExplorerFilesystem.createFolder(at: url).get() == url)

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        #expect(isDirectory.boolValue)
    }

    @Test func createRefusesAnExistingName() throws {
        let base = try tempDirectory()
        try makeFile(base, "a.txt")
        #expect(throws: (any Error).self) {
            try FileExplorerFilesystem.createFile(at: base.appendingPathComponent("a.txt")).get()
        }
    }

    @Test func createFileTakesTheNameAndTheFolderSeparately() throws {
        let base = try tempDirectory()
        let url = try FileExplorerFilesystem.createFile(named: "notes.txt", in: base).get()

        #expect(url == base.appendingPathComponent("notes.txt"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func createFolderTakesTheNameAndTheFolderSeparately() throws {
        let base = try tempDirectory()
        let url = try FileExplorerFilesystem.createFolder(named: "src", in: base).get()

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        #expect(isDirectory.boolValue)
    }

    @Test func createRefusesANameWithAPathSeparator() throws {
        let base = try tempDirectory()
        #expect(throws: (any Error).self) {
            try FileExplorerFilesystem.createFile(named: "a/b.txt", in: base).get()
        }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("a").path))
    }

    /// The traversal the old check could not see. `appendingPathComponent`
    /// eats the "..", so by the time the name reached the filesystem its
    /// `lastPathComponent` was the perfectly ordinary "escape.txt" — while
    /// the URL pointed one directory above the tree. The typed string is the
    /// only place the climb is still visible, so it is the only place worth
    /// checking.
    @Test func createRefusesANameThatClimbsOutOfTheFolder() throws {
        let base = try tempDirectory()
        let inside = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try FileExplorerFilesystem.createFile(named: "../escape.txt", in: inside).get()
        }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("escape.txt").path))
    }

    @Test func createFolderRefusesANameThatClimbsOutOfTheFolder() throws {
        let base = try tempDirectory()
        let inside = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try FileExplorerFilesystem.createFolder(named: "../escaped", in: inside).get()
        }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("escaped").path))
    }

    @Test func createRefusesAnAbsolutePath() throws {
        let base = try tempDirectory()
        #expect(throws: (any Error).self) {
            try FileExplorerFilesystem.createFile(named: "/tmp/elsewhere.txt", in: base).get()
        }
    }

    @Test func createRefusesTheDotNames() throws {
        let base = try tempDirectory()
        #expect(throws: (any Error).self) {
            try FileExplorerFilesystem.createFile(named: "..", in: base).get()
        }
        #expect(throws: (any Error).self) {
            try FileExplorerFilesystem.createFolder(named: ".", in: base).get()
        }
    }

    // MARK: Copy and drop origin

    /// A file dragged in from Finder is copied, so the original stays where
    /// its owner left it.
    @Test func copyLeavesTheOriginalBehind() throws {
        let base = try tempDirectory()
        try makeFile(base, "a.txt")
        try makeDir(base, "folder")

        let source = base.appendingPathComponent("a.txt")
        let target = try FileExplorerFilesystem.copy(
            source, into: base.appendingPathComponent("folder", isDirectory: true)
        ).get()

        #expect(target.path == base.appendingPathComponent("folder/a.txt").path)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(FileManager.default.fileExists(atPath: source.path), "the original must survive")
    }

    @Test func copyRefusesANameClash() throws {
        let base = try tempDirectory()
        try makeFile(base, "a.txt")
        try makeDir(base, "folder")
        try makeFile(base, "folder/a.txt")

        #expect(throws: (any Error).self) {
            try FileExplorerFilesystem.copy(
                base.appendingPathComponent("a.txt"),
                into: base.appendingPathComponent("folder", isDirectory: true)
            ).get()
        }
    }

    @Test func somethingAlreadyInTheTreeCountsAsInside() {
        #expect(FileExplorerFilesystem.isInside(URL(fileURLWithPath: "/work/app/a.ts"), root: "/work"))
        #expect(FileExplorerFilesystem.isInside(URL(fileURLWithPath: "/work"), root: "/work"))
    }

    @Test func somethingFromElsewhereCountsAsOutside() {
        #expect(!FileExplorerFilesystem.isInside(
            URL(fileURLWithPath: "/Users/x/Downloads/a.ts"), root: "/work"
        ))
    }

    /// A sibling whose name starts with the root's is not inside it — the
    /// same separator rule the editor's own repath needs.
    @Test func aSiblingSharingTheRootsPrefixIsOutside() {
        #expect(!FileExplorerFilesystem.isInside(URL(fileURLWithPath: "/work-2/a.ts"), root: "/work"))
    }

    @Test func nothingIsInsideAnAbsentRoot() {
        #expect(!FileExplorerFilesystem.isInside(URL(fileURLWithPath: "/work/a.ts"), root: ""))
    }

    // MARK: Unique and proposed names

    @Test func proposedNamesFollowTheUntitledConvention() {
        #expect(FileExplorerFilesystem.proposedName(isFolder: false) == "untitled.txt")
        #expect(FileExplorerFilesystem.proposedName(isFolder: true) == "untitled folder")
    }

    @Test func uniqueNameKeepsTheNameWhenFree() throws {
        let base = try tempDirectory()
        let url = base.appendingPathComponent("untitled.txt")
        #expect(FileExplorerFilesystem.uniqueName(for: url) == url)
    }

    @Test func uniqueNameNumberedTheFirstCollision() throws {
        let base = try tempDirectory()
        try makeFile(base, "untitled.txt")

        let url = base.appendingPathComponent("untitled.txt")
        #expect(FileExplorerFilesystem.uniqueName(for: url).lastPathComponent == "untitled 2.txt")
    }

    @Test func uniqueNameWalksPastOccupiedNumbers() throws {
        let base = try tempDirectory()
        try makeFile(base, "untitled.txt")
        try makeFile(base, "untitled 2.txt")
        try makeFile(base, "untitled 3.txt")

        let url = base.appendingPathComponent("untitled.txt")
        #expect(FileExplorerFilesystem.uniqueName(for: url).lastPathComponent == "untitled 4.txt")
    }

    @Test func uniqueNameForAFolderDropsTheExtension() throws {
        let base = try tempDirectory()
        try makeDir(base, "untitled folder")

        let url = base.appendingPathComponent("untitled folder", isDirectory: true)
        #expect(FileExplorerFilesystem.uniqueName(for: url).lastPathComponent == "untitled folder 2")
    }
}
