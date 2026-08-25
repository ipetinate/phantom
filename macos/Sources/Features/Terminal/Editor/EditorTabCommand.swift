import Foundation

/// One command an open file's tab offers.
///
/// A value rather than menu-building code, for the reason
/// `FileExplorerRowCommand` is one: the menu has two openings — a right-click
/// and a double click — and a menu written out twice is a menu that drifts.
/// Which commands exist, in what order, where a separator falls and which
/// glyph each carries are answered once, here.
///
/// Reordering is a pair of commands rather than a drag inside the bar, and
/// that is a concession to the gesture already there. Every tab in the bar is
/// a drag *source* for moving between cells — `EditorTabDragSource` begins an
/// AppKit session on `mouseDragged` — and the drop target that answers it is
/// the whole cell, which reads the bar as a join and any drop on it as "move
/// this tab into this cell" (`EditorDropZone.resolve`). A second target
/// inside the bar would have to register the same private type and win the
/// same drag, and the cross-cell gesture took three attempts to make behave.
/// A menu item costs a click and breaks nothing.
enum EditorTabCommand: String, Equatable, Hashable, CaseIterable {
    case close
    case closeOthers
    case closeAll
    case pin
    case unpin
    case moveLeft
    case moveRight
    case splitLeading
    case splitTrailing
    case splitTop
    case splitBottom
    case moveToMainPane
    case revealInFinder
    case copyPath

    var title: String {
        switch self {
        case .close: return "Close"
        case .closeOthers: return "Close Others"
        case .closeAll: return "Close All"
        case .pin: return "Pin"
        case .unpin: return "Unpin"
        case .moveLeft: return "Move Left"
        case .moveRight: return "Move Right"
        case .splitLeading: return "Split Left"
        case .splitTrailing: return "Split Right"
        case .splitTop: return "Split Up"
        case .splitBottom: return "Split Down"
        case .moveToMainPane: return "Move to Main Pane"
        case .revealInFinder: return "Reveal in Finder"
        case .copyPath: return "Copy Path"
        }
    }

    /// The glyph beside the title.
    ///
    /// Direction is what the four splits are *for*, so they carry an arrow
    /// each rather than four variations on a divided rectangle — at menu size
    /// those differ by a few pixels of fill and read as the same icon.
    ///
    /// Every name here is asserted to resolve in `EditorTabCommandTests`: an
    /// SF Symbol this build cannot draw is not an error, it is a menu item
    /// with a hole where its icon should be.
    var icon: String {
        switch self {
        case .close: return "xmark"
        case .closeOthers: return "xmark.circle"
        case .closeAll: return "xmark.circle.fill"
        case .pin: return "pin"
        case .unpin: return "pin.slash"
        /// Bare arrows, where the four splits carry boxed ones: reordering
        /// slides the tab along a row and dividing hands it half a cell, and
        /// at menu size the box is the only thing that says which is which.
        case .moveLeft: return "arrow.backward"
        case .moveRight: return "arrow.forward"
        case .splitLeading: return "arrow.left.square"
        case .splitTrailing: return "arrow.right.square"
        case .splitTop: return "arrow.up.square"
        case .splitBottom: return "arrow.down.square"
        case .moveToMainPane: return "arrow.uturn.backward"
        case .revealInFinder: return "folder"
        case .copyPath: return "doc.on.doc"
        }
    }

    /// Which run of items this belongs to. A separator goes wherever the group
    /// changes, so removing a command cannot leave a rule against nothing —
    /// the rule the explorer's menu already follows.
    var group: Int {
        switch self {
        case .close, .closeOthers, .closeAll: return 0
        case .pin, .unpin, .moveLeft, .moveRight: return 1
        case .splitLeading, .splitTrailing, .splitTop, .splitBottom, .moveToMainPane: return 2
        case .revealInFinder, .copyPath: return 3
        }
    }

    /// Which edge this command divides towards, or nil when it divides nothing.
    var zone: EditorDropZone? {
        switch self {
        case .splitLeading: return .leading
        case .splitTrailing: return .trailing
        case .splitTop: return .top
        case .splitBottom: return .bottom
        default: return nil
        }
    }

    /// What a tab can be asked to do, which depends on where it is.
    ///
    /// A struct rather than three loose parameters: the menu is built at two
    /// call sites and asserted at a third, and a bare `(true, false, true)`
    /// at any of them is a bug nobody sees.
    struct Availability: Equatable {
        /// Whether the bar holds more than this tab.
        var hasSiblings: Bool

        /// Whether the cell has anything left when this tab leaves it — see
        /// `EditorCenter.canSplitOut`. A lone tab dividing its own cell heals
        /// straight back, so the commands are left out rather than offered as
        /// a no-op.
        var canSplitOut: Bool

        /// Whether this tab is somewhere other than the main pane, which is
        /// the only case where sending it there does anything.
        var canReturnToMainPane: Bool

        /// Whether this tab is already pinned, which decides which half of
        /// the pin pair the menu offers. Two commands rather than one that
        /// changes its name: `title` and `icon` are read off the case alone,
        /// and a case that had to be asked what it is called would have to be
        /// handed the availability at both call sites and at the test.
        var isPinned: Bool

        /// Whether the tab has a neighbour to trade places with on that side,
        /// **inside its own run** — see `EditorTabSet.canMove`. The pinned run
        /// reorders among itself and the unpinned among itself, so at either
        /// end of a run the item is left out rather than offered as a no-op.
        var canMoveLeft: Bool
        var canMoveRight: Bool
    }

    private func isOffered(_ availability: Availability) -> Bool {
        switch self {
        case .closeOthers: return availability.hasSiblings
        case .pin: return !availability.isPinned
        case .unpin: return availability.isPinned
        case .moveLeft: return availability.canMoveLeft
        case .moveRight: return availability.canMoveRight
        case .splitLeading, .splitTrailing, .splitTop, .splitBottom:
            return availability.canSplitOut
        case .moveToMainPane: return availability.canReturnToMainPane
        default: return true
        }
    }

    /// The tab's menu, separators already placed.
    ///
    /// With one tab open, "Close Others" would close nothing and "Close All"
    /// is already "Close" — the first is dropped and the second is kept,
    /// because a reader who wants everything gone reaches for it by name
    /// rather than counting tabs first.
    static func menu(_ availability: Availability) -> [EditorTabMenuEntry] {
        let commands = allCases.filter { $0.isOffered(availability) }

        var entries: [EditorTabMenuEntry] = []
        var lastGroup: Int?

        for command in commands {
            if let lastGroup, lastGroup != command.group {
                entries.append(.separator)
            }
            entries.append(.command(command))
            lastGroup = command.group
        }

        return entries
    }
}

/// A row of the tab's menu: a command, or the rule between two runs of them.
enum EditorTabMenuEntry: Equatable {
    case command(EditorTabCommand)
    case separator
}
