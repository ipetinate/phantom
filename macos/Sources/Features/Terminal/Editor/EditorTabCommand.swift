import Foundation

/// One command an open file's tab offers.
///
/// A value rather than menu-building code, for the reason
/// `FileExplorerRowCommand` is one: the menu has two openings — a right-click
/// and a double click — and a menu written out twice is a menu that drifts.
/// Which commands exist, in what order, where a separator falls and which
/// glyph each carries are answered once, here.
enum EditorTabCommand: String, Equatable, Hashable, CaseIterable {
    case close
    case closeOthers
    case closeAll
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
        case .splitLeading, .splitTrailing, .splitTop, .splitBottom, .moveToMainPane: return 1
        case .revealInFinder, .copyPath: return 2
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
    }

    private func isOffered(_ availability: Availability) -> Bool {
        switch self {
        case .closeOthers: return availability.hasSiblings
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
