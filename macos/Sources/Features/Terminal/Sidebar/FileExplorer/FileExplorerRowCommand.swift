import Foundation

/// One command the file explorer's row menu offers.
///
/// A value rather than menu-building code, for the reason
/// `EditorContextCommand` is one — and here for a second reason the editor
/// never had: this menu now has two openings. A right-click draws it as
/// SwiftUI buttons, a double click pops it as an `NSMenu` at the pointer, and
/// a menu written out twice is a menu that drifts. Which commands exist, in
/// what order, and where a separator falls are answered once, here.
enum FileExplorerRowCommand: String, Equatable, Hashable, CaseIterable {
    case newFile
    case newFolder
    case rename
    case delete
    case revealInFinder
    case copyPath

    var title: String {
        switch self {
        case .newFile: return "New File"
        case .newFolder: return "New Folder"
        case .rename: return "Rename"
        case .delete: return "Delete"
        case .revealInFinder: return "Reveal in Finder"
        case .copyPath: return "Copy Path"
        }
    }

    /// Which run of items this belongs to. A separator goes wherever the group
    /// changes, so removing a command cannot leave a rule against nothing —
    /// the rule `EditorContextCommand.group` already follows.
    var group: Int {
        switch self {
        case .newFile, .newFolder: return 0
        case .rename, .delete: return 1
        case .revealInFinder, .copyPath: return 2
        }
    }

    /// Tinted red by the SwiftUI renderer, which is the pre-existing
    /// treatment and stays with the one command nothing in the app undoes.
    ///
    /// Read by that renderer alone. `NSMenu` is left to draw its items the way
    /// macOS draws every other menu, because a red row that inverts to white
    /// on highlight is a worse difference between the two openings than a
    /// black one.
    var isDestructive: Bool { self == .delete }

    /// Only a folder can be created inside, so only a folder offers the two
    /// commands that create.
    private var needsDirectory: Bool {
        switch self {
        case .newFile, .newFolder: return true
        default: return false
        }
    }

    /// The row's menu, separators already placed.
    ///
    /// Placed here rather than by each renderer: both of them then walk one
    /// list and neither can re-derive the rules differently. It is also the
    /// form an assertion wants — "this is the menu a folder offers, in this
    /// order" is one comparison.
    static func menu(isDirectory: Bool) -> [FileExplorerRowMenuEntry] {
        let commands = allCases.filter { isDirectory || !$0.needsDirectory }

        var entries: [FileExplorerRowMenuEntry] = []
        var previous: FileExplorerRowCommand?
        for command in commands {
            if let previous, previous.group != command.group {
                entries.append(.separator)
            }
            entries.append(.command(command))
            previous = command
        }
        return entries
    }
}

/// A row of the row menu: a command, or the rule between two groups of them.
enum FileExplorerRowMenuEntry: Equatable, Hashable {
    case command(FileExplorerRowCommand)
    case separator
}

/// Which of the two gestures a click on a row is.
///
/// A single click opens — a file into the pane or the terminal, a folder by
/// expanding — and a double click offers the menu. AppKit hands SwiftUI two
/// separate taps for a double click, so the second one has to be *recognised*
/// rather than waited for: a `TapGesture(count: 2)` makes every single click
/// in the tree wait out the system's double-click interval before the file
/// opens, and a file list that trails a quarter of a second behind the
/// pointer is the thing this tree is careful about everywhere else.
///
/// The price of not waiting is that the first click of a double click has
/// already opened the row. That is the trade — the alternative is a slow tree
/// — and it is exactly why the second click must not open it *again*: two
/// `FileOpener.prompt` calls for one gesture spawn two terminals, or stack two
/// modal alerts, depending on the destination the reader configured.
enum FileExplorerRowClick: Equatable {
    case open
    case menu

    /// Both times are `Date.timeIntervalSinceReferenceDate`, and `interval` is
    /// `NSEvent.doubleClickInterval` — the reader's own setting rather than a
    /// number chosen here, so a slow double click is whatever macOS says it
    /// is.
    static func resolve(
        at time: TimeInterval,
        previous: TimeInterval?,
        interval: TimeInterval
    ) -> FileExplorerRowClick {
        guard let previous, time >= previous, time - previous <= interval else { return .open }
        return .menu
    }
}
