import Foundation
@testable import Ghostty
import Testing

/// Walking the file tree from the keyboard: what ↑, ↓, ←, → and Space answer
/// for a given list of rows.
///
/// Clicking a file used to be the end of the interaction — the selection was
/// something three commands read and nothing could move. These are the
/// conventions a macOS outline view has: step through what is visible, → to
/// open a folder and then to go into it, ← to close it and then to come back
/// out, Space to open what is selected.
struct FileTreeNavigationTests {
    private func file(_ path: String, depth: Int) -> FileRow {
        row(path, depth: depth, isDirectory: false)
    }

    private func folder(_ path: String, depth: Int) -> FileRow {
        row(path, depth: depth, isDirectory: true)
    }

    private func row(_ path: String, depth: Int, isDirectory: Bool) -> FileRow {
        FileRow(
            node: FileNode(
                url: URL(fileURLWithPath: path, isDirectory: isDirectory),
                name: (path as NSString).lastPathComponent,
                isDirectory: isDirectory
            ),
            depth: depth
        )
    }

    /// The tree every test below reads, with `/w/src` open and `/w/src/ui`
    /// closed:
    ///
    ///     src/
    ///       app.swift
    ///       ui/
    ///     readme.md
    private var rows: [FileRow] {
        [
            folder("/w/src", depth: 0),
            file("/w/src/app.swift", depth: 1),
            folder("/w/src/ui", depth: 1),
            file("/w/readme.md", depth: 0),
        ]
    }

    private func navigation(
        rows: [FileRow]? = nil,
        expanded: Set<String> = ["/w/src"],
        selection: String?
    ) -> FileTreeNavigation {
        FileTreeNavigation(
            rows: rows ?? self.rows,
            expanded: expanded,
            selection: selection
        )
    }

    // MARK: Stepping

    @Test func downMovesToTheNextVisibleRow() {
        #expect(
            navigation(selection: "/w/src").command(for: .down)
                == .select("/w/src/app.swift")
        )
    }

    @Test func upMovesToThePreviousVisibleRow() {
        #expect(
            navigation(selection: "/w/src/app.swift").command(for: .up)
                == .select("/w/src")
        )
    }

    /// Coming out of a folder is a step up the list, not a step out of it: the
    /// row above `readme.md` is the closed folder two levels in, and that is
    /// where ↑ goes.
    @Test func steppingIgnoresIndentation() {
        #expect(
            navigation(selection: "/w/readme.md").command(for: .up)
                == .select("/w/src/ui")
        )
    }

    /// Clamped, not wrapped. A list that jumps from its last row back to its
    /// first has lost the reader.
    @Test func downAtTheLastRowDoesNothing() {
        #expect(navigation(selection: "/w/readme.md").command(for: .down) == .nothing)
    }

    @Test func upAtTheFirstRowDoesNothing() {
        #expect(navigation(selection: "/w/src").command(for: .up) == .nothing)
    }

    /// What a closed folder holds is not stepped through, because it isn't on
    /// screen — the rows are the whole truth about that.
    @Test func aClosedFoldersChildrenAreNotSteppedThrough() {
        let closed = navigation(
            rows: [folder("/w/src", depth: 0), file("/w/readme.md", depth: 0)],
            expanded: [],
            selection: "/w/src"
        )

        #expect(closed.command(for: .down) == .select("/w/readme.md"))
    }

    // MARK: →

    @Test func rightOpensAClosedFolder() {
        let command = navigation(selection: "/w/src/ui").command(for: .right)

        #expect(command == .expand(folder("/w/src/ui", depth: 1).node))
    }

    /// Once it is open, → is how you go in — to the first child, never to the
    /// folder's own sibling.
    @Test func rightGoesIntoAnOpenFolder() {
        #expect(
            navigation(selection: "/w/src").command(for: .right)
                == .select("/w/src/app.swift")
        )
    }

    /// An open folder with no children rows: either empty, or its listing
    /// hasn't landed yet. Both have to leave the selection where it is —
    /// stepping onto the next row would step *past* the folder.
    @Test func rightIntoAnOpenFolderWithNothingUnderItDoesNothing() {
        let loading = navigation(
            rows: [folder("/w/src", depth: 0), file("/w/readme.md", depth: 0)],
            expanded: ["/w/src"],
            selection: "/w/src"
        )

        #expect(loading.command(for: .right) == .nothing)
    }

    @Test func rightOnAFileDoesNothing() {
        #expect(navigation(selection: "/w/src/app.swift").command(for: .right) == .nothing)
    }

    // MARK: ←

    @Test func leftClosesAnOpenFolder() {
        let command = navigation(selection: "/w/src").command(for: .left)

        #expect(command == .collapse(folder("/w/src", depth: 0).node))
    }

    @Test func leftFromAFileGoesToTheFolderHoldingIt() {
        #expect(
            navigation(selection: "/w/src/app.swift").command(for: .left)
                == .select("/w/src")
        )
    }

    /// A closed folder has nothing to close, so ← means the same thing it
    /// means on a file: come out one level.
    @Test func leftFromAClosedFolderGoesToItsParent() {
        #expect(
            navigation(selection: "/w/src/ui").command(for: .left)
                == .select("/w/src")
        )
    }

    /// The root has no row of its own, so there is nowhere further out to go.
    @Test func leftAtTheTopLevelDoesNothing() {
        #expect(navigation(selection: "/w/readme.md").command(for: .left) == .nothing)
    }

    /// The parent is the nearest row one level out, not the first row above at
    /// any lesser depth — three levels deep, ← lands on the folder that holds
    /// the file rather than on the project's own folder.
    @Test func leftFindsTheNearestParentNotTheOutermost() {
        let deep = navigation(
            rows: [
                folder("/w/src", depth: 0),
                folder("/w/src/ui", depth: 1),
                file("/w/src/ui/view.swift", depth: 2),
            ],
            expanded: ["/w/src", "/w/src/ui"],
            selection: "/w/src/ui/view.swift"
        )

        #expect(deep.command(for: .left) == .select("/w/src/ui"))
    }

    // MARK: Space

    @Test func spaceOpensTheSelectedFile() {
        let command = navigation(selection: "/w/readme.md").command(for: .activate)

        #expect(command == .open(file("/w/readme.md", depth: 0).node))
    }

    @Test func spaceOpensAClosedFolder() {
        #expect(
            navigation(selection: "/w/src/ui").command(for: .activate)
                == .expand(folder("/w/src/ui", depth: 1).node)
        )
    }

    @Test func spaceClosesAnOpenFolder() {
        #expect(
            navigation(selection: "/w/src").command(for: .activate)
                == .collapse(folder("/w/src", depth: 0).node)
        )
    }

    // MARK: Nothing selected

    /// A tree nobody has clicked in yet still has to answer the first arrow,
    /// or the keyboard reads as unwired.
    @Test func theFirstArrowSelectsTheFirstRow() {
        let untouched = navigation(selection: nil)

        #expect(untouched.command(for: .down) == .select("/w/src"))
        #expect(untouched.command(for: .up) == .select("/w/src"))
        #expect(untouched.command(for: .left) == .select("/w/src"))
        #expect(untouched.command(for: .right) == .select("/w/src"))
    }

    /// Space is the one key that doesn't: it acts *on* the selection, and
    /// opening whatever happens to be at the top of the tree is not what
    /// anybody pressed it for.
    @Test func spaceWithNothingSelectedDoesNothing() {
        #expect(navigation(selection: nil).command(for: .activate) == .nothing)
    }

    /// The selection outlives the row it names — a folder collapsing takes its
    /// children off screen, a search replaces the tree entirely — and the
    /// keyboard has to land somewhere real when that happens.
    @Test func aSelectionThatIsNoLongerOnScreenStartsFromTheTop() {
        let collapsed = navigation(
            rows: [folder("/w/src", depth: 0), file("/w/readme.md", depth: 0)],
            expanded: [],
            selection: "/w/src/app.swift"
        )

        #expect(collapsed.command(for: .down) == .select("/w/src"))
        #expect(collapsed.command(for: .activate) == .nothing)
    }

    @Test func anEmptyTreeAnswersNothing() {
        let empty = navigation(rows: [], expanded: [], selection: nil)

        #expect(empty.command(for: .down) == .nothing)
        #expect(empty.command(for: .activate) == .nothing)
    }

    // MARK: Rows that aren't places

    /// "12 more…" carries the *folder's* path, not a file's, so landing on it
    /// would quietly move the selection back up a level — and Space would then
    /// collapse the folder the reader was looking inside.
    @Test func theTruncationNoticeIsSteppedOver() {
        let truncated = navigation(
            rows: [
                folder("/w/src", depth: 0),
                file("/w/src/app.swift", depth: 1),
                FileRow(
                    node: FileNode(
                        url: URL(fileURLWithPath: "/w/src", isDirectory: true),
                        name: "12 more…",
                        isDirectory: false
                    ),
                    depth: 1,
                    isTruncationNotice: true
                ),
                file("/w/readme.md", depth: 0),
            ],
            selection: "/w/src/app.swift"
        )

        #expect(truncated.command(for: .down) == .select("/w/readme.md"))
    }

    /// The name being typed into a create field is not a file yet. Keys don't
    /// reach the tree while a field is open, so this is the belt to that
    /// braces: the row is skipped wherever it is asked about.
    @Test func theCreatePlaceholderIsSteppedOver() {
        let creating = navigation(
            rows: [
                folder("/w/src", depth: 0),
                FileRow(
                    node: FileNode(
                        url: URL(fileURLWithPath: "/w/src/untitled"),
                        name: "untitled",
                        isDirectory: false
                    ),
                    depth: 1,
                    isCreatePlaceholder: true
                ),
                file("/w/readme.md", depth: 0),
            ],
            selection: "/w/src"
        )

        #expect(creating.command(for: .down) == .select("/w/readme.md"))
        #expect(creating.command(for: .right) == .nothing)
    }

    // MARK: Which press is which key

    /// An arrow reports a character in the private use area rather than
    /// anything printable, and it is the same one the shortcut recorder stores
    /// — so a binding shown as ↑ and a press read as ↑ are the same key.
    @Test func theArrowsAndSpaceAreRecognised() {
        #expect(FileTreeNavigation.Key(character: Character(PhantomShortcut.upArrow)) == .up)
        #expect(FileTreeNavigation.Key(character: Character(PhantomShortcut.downArrow)) == .down)
        #expect(FileTreeNavigation.Key(character: Character(PhantomShortcut.leftArrow)) == .left)
        #expect(FileTreeNavigation.Key(character: Character(PhantomShortcut.rightArrow)) == .right)
        #expect(FileTreeNavigation.Key(character: " ") == .activate)
    }

    /// Everything else falls through, which is what leaves Return on rename,
    /// Delete on trash, and every letter to whatever claims it.
    @Test func anyOtherKeyIsNotNavigation() {
        #expect(FileTreeNavigation.Key(character: "n") == nil)
        #expect(FileTreeNavigation.Key(character: "\r") == nil)
        #expect(FileTreeNavigation.Key(character: "\u{7F}") == nil)
    }
}
