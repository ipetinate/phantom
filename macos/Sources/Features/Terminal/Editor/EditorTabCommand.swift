import Foundation

/// One command an open file's tab offers.
///
/// A value rather than menu-building code, for the reason
/// `FileExplorerRowCommand` is one: the menu has two openings — a right-click
/// drawn as SwiftUI buttons and a double click popped as an `NSMenu` at the
/// pointer — and a menu written out twice is a menu that drifts. Which
/// commands exist, in what order, and where a separator falls are answered
/// once, here.
enum EditorTabCommand: String, Equatable, Hashable, CaseIterable {
    case close
    case closeOthers
    case closeAll
    case revealInFinder
    case copyPath

    var title: String {
        switch self {
        case .close: return "Close"
        case .closeOthers: return "Close Others"
        case .closeAll: return "Close All"
        case .revealInFinder: return "Reveal in Finder"
        case .copyPath: return "Copy Path"
        }
    }

    /// Which run of items this belongs to. A separator goes wherever the group
    /// changes, so removing a command cannot leave a rule against nothing —
    /// the rule the explorer's menu already follows.
    var group: Int {
        switch self {
        case .close, .closeOthers, .closeAll: return 0
        case .revealInFinder, .copyPath: return 1
        }
    }

    /// The two commands that need a second tab to mean anything.
    private var needsSiblings: Bool {
        switch self {
        case .closeOthers: return true
        default: return false
        }
    }

    /// The tab's menu, separators already placed.
    ///
    /// - Parameter hasSiblings: whether the cell holds more than this tab.
    ///   With one tab open, "Close Others" would close nothing and "Close
    ///   All" is already "Close" — the first is dropped and the second is
    ///   kept, because a reader who wants everything gone reaches for it by
    ///   name rather than counting tabs first.
    static func menu(hasSiblings: Bool) -> [EditorTabMenuEntry] {
        let commands = allCases.filter { hasSiblings || !$0.needsSiblings }

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
