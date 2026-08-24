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
    case openLeading
    case openTrailing
    case openTop
    case openBottom
    case moveToMainPane
    case rename
    case delete
    case revealInFinder
    case copyPath

    var title: String {
        switch self {
        case .newFile: return "New File"
        case .newFolder: return "New Folder"
        case .openLeading: return "Open in Split Left"
        case .openTrailing: return "Open in Split Right"
        case .openTop: return "Open in Split Up"
        case .openBottom: return "Open in Split Down"
        case .moveToMainPane: return "Move to Main Pane"
        case .rename: return "Rename"
        case .delete: return "Delete"
        case .revealInFinder: return "Reveal in Finder"
        case .copyPath: return "Copy Path"
        }
    }

    /// The glyph beside the title, in the same vocabulary the tab menu uses —
    /// the two menus sit inches apart and offer some of the same commands, so
    /// a command that appears in both looks the same in both.
    ///
    /// Asserted to resolve in `FileExplorerTests`: an SF Symbol this build
    /// cannot draw is a menu item with a hole where its icon should be.
    var icon: String {
        switch self {
        case .newFile: return "doc.badge.plus"
        case .newFolder: return "folder.badge.plus"
        case .openLeading: return "arrow.left.square"
        case .openTrailing: return "arrow.right.square"
        case .openTop: return "arrow.up.square"
        case .openBottom: return "arrow.down.square"
        case .moveToMainPane: return "arrow.uturn.backward"
        case .rename: return "pencil"
        case .delete: return "trash"
        case .revealInFinder: return "folder"
        case .copyPath: return "doc.on.doc"
        }
    }

    /// Which edge this command opens the file towards, or nil when it opens
    /// nothing to a side.
    var zone: EditorDropZone? {
        switch self {
        case .openLeading: return .leading
        case .openTrailing: return .trailing
        case .openTop: return .top
        case .openBottom: return .bottom
        default: return nil
        }
    }

    /// Which run of items this belongs to. A separator goes wherever the group
    /// changes, so removing a command cannot leave a rule against nothing —
    /// the rule `EditorContextCommand.group` already follows.
    var group: Int {
        switch self {
        case .newFile, .newFolder: return 0
        case .openLeading, .openTrailing, .openTop, .openBottom, .moveToMainPane: return 1
        case .rename, .delete: return 2
        case .revealInFinder, .copyPath: return 3
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

    /// A folder has nothing to open into a pane, so the split commands belong
    /// to files alone.
    private var needsFile: Bool {
        switch self {
        case .openLeading, .openTrailing, .openTop, .openBottom, .moveToMainPane:
            return true
        default:
            return false
        }
    }

    /// What a row can be asked to do, beyond what its kind already decides.
    struct Availability: Equatable {
        var isDirectory: Bool

        /// Whether the pane can be divided for this file at all — see
        /// `EditorCenter.canSplitOut`. A file that is the only thing in the
        /// only cell divides into a split that heals straight back.
        var canSplit: Bool

        /// Whether this file is open somewhere other than the main pane, the
        /// one case where sending it there does anything.
        var canReturnToMainPane: Bool
    }

    private func isOffered(_ availability: Availability) -> Bool {
        if needsDirectory { return availability.isDirectory }
        if needsFile && availability.isDirectory { return false }

        switch self {
        case .openLeading, .openTrailing, .openTop, .openBottom:
            return availability.canSplit
        case .moveToMainPane:
            return availability.canReturnToMainPane
        default:
            return true
        }
    }

    /// The row's menu, separators already placed.
    ///
    /// Placed here rather than by each renderer: both of them then walk one
    /// list and neither can re-derive the rules differently. It is also the
    /// form an assertion wants — "this is the menu a folder offers, in this
    /// order" is one comparison.
    static func menu(_ availability: Availability) -> [FileExplorerRowMenuEntry] {
        let commands = allCases.filter { $0.isOffered(availability) }

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

/// What a row's menu needs from the editor: what it may offer, and the two
/// commands only the editor can run.
///
/// One value rather than three parameters on the row, and not for tidiness:
/// three more arguments in that initializer put the tree's row past what the
/// SwiftUI type checker will solve, and it says so by failing the build.
@MainActor
struct FileExplorerRowMenu {
    var availability: FileExplorerRowCommand.Availability
    var openInSplit: (EditorDropZone) -> Void
    var moveToMainPane: () -> Void
}
