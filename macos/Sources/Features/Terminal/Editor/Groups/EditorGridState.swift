import CoreGraphics
import Foundation

/// The editor grid as it is written to the session file and read back.
///
/// A shape of its own rather than `Codable` on `EditorGroupTree`, for two
/// reasons.
///
/// The model carries values that must not outlive a launch. A tab's dirty
/// dot belongs to a buffer this does not save — restoring unsaved text is
/// the undo timeline's job, and two writers over the same bytes is two
/// sources of truth. A cell id and a split id are only ever compared inside
/// one run. Conforming the model would put all of them in the file by
/// default, and every field added to a tab afterwards would follow them in
/// without anyone deciding it should.
///
/// The other reason is ownership: the tab set lives in a file this does not
/// own, and a persisted shape that names its fields explicitly keeps the
/// on-disk format a decision made in one place.
struct EditorGridState: Codable, Equatable {
    /// The layout: a tree of splits with a cell at every leaf, mirroring
    /// `EditorGroupTree`.
    var root: Node

    indirect enum Node: Equatable {
        case leaf(Cell)
        case split(Split)
    }

    /// One division, without the split's runtime id.
    ///
    /// The id exists so a view can key a dragging divider to a binding that
    /// survives the drag. It is meaningless a launch later, so it is not
    /// written and a fresh one is made on the way back.
    struct Split: Codable, Equatable {
        var direction: SplitViewDirection
        var ratio: CGFloat
        var first: Node
        var second: Node
    }

    /// One cell: what was open in it, what it was showing, and whether the
    /// terminal lived there.
    struct Cell: Codable, Equatable {
        /// In tab-bar order, pinned run first — the order `EditorTabSet`
        /// keeps, so replaying it reproduces the bar exactly.
        var files: [File]

        /// The file the cell was showing, or nil for the terminal.
        ///
        /// A cell showing the branch review records nil too. The review is
        /// not a file: it has no path, and which review was open is state of
        /// the window rather than of the cell. Restoring it would mean
        /// reconstructing a git scope that may no longer exist, so a cell
        /// that was showing one comes back on the terminal or on its last
        /// file, both of which are still there.
        var selectedFile: String?

        var hostsTerminal: Bool

        /// Whether this was the cell being worked in. Exactly one cell in a
        /// saved grid carries it.
        var isActive: Bool
    }

    /// One open file. The path and the pin, and deliberately nothing else:
    /// the dirty flag describes a buffer this does not save.
    struct File: Codable, Equatable {
        var path: String
        var isPinned: Bool
    }
}

// MARK: Reading a live grid

extension EditorGridState {
    /// The arrangement of a window's editor, or nil when there is nothing in
    /// it worth bringing back.
    ///
    /// A grid of one cell with no files is the shape every window starts in.
    /// Recording it would add a block to the session file for every terminal
    /// that never opened a file, and restoring it would rebuild what the
    /// window already is.
    @MainActor
    init?(capturing center: EditorCenter) {
        guard center.tree.groups.contains(where: { !$0.tabs.isEmpty }) else { return nil }
        self.init(center.tree, activeGroupID: center.activeGroupID)
    }

    init(_ tree: EditorGroupTree, activeGroupID: EditorGroup.ID) {
        root = Node(tree, activeGroupID: activeGroupID)
    }

    /// Every saved path, in cell order.
    ///
    /// What the restore opens, before it knows what shape to put the results
    /// in — see `EditorCenter.restore`.
    var paths: [String] {
        root.cells.flatMap { cell in cell.files.map(\.path) }
    }
}

extension EditorGridState.Node {
    init(_ tree: EditorGroupTree, activeGroupID: EditorGroup.ID) {
        switch tree {
        case .leaf(let group):
            self = .leaf(EditorGridState.Cell(group, isActive: group.id == activeGroupID))

        case .split(let split):
            self = .split(EditorGridState.Split(
                direction: split.direction,
                ratio: split.ratio,
                first: .init(split.first, activeGroupID: activeGroupID),
                second: .init(split.second, activeGroupID: activeGroupID)))
        }
    }

    /// Every cell, in layout order.
    var cells: [EditorGridState.Cell] {
        switch self {
        case .leaf(let cell):
            return [cell]
        case .split(let split):
            return split.first.cells + split.second.cells
        }
    }
}

extension EditorGridState.Cell {
    init(_ group: EditorGroup, isActive: Bool) {
        files = group.tabs.tabs.map { .init(path: $0.path, isPinned: $0.isPinned) }
        selectedFile = group.tabs.selection.path
        hostsTerminal = group.hostsTerminal
        self.isActive = isActive
    }
}

// MARK: Building the grid back

extension EditorGridState {
    /// A saved grid turned back into a live one.
    struct Rebuilt: Equatable {
        var tree: EditorGroupTree
        var activeGroupID: EditorGroup.ID
    }

    /// The tree to restore, keeping only the files that can still be opened.
    ///
    /// One missing file costs its own tab and nothing else. A cell that loses
    /// every file collapses and its sibling takes the space, which is the
    /// same rule the grid follows while the reader is using it — a cell with
    /// no files and no terminal is a hole with nothing to draw in it.
    ///
    /// - Parameter isOpen: whether a saved path made it back. Injected rather
    ///   than read from disk here so the rule can be tested without files,
    ///   and so the caller can answer with what actually *opened* — a file
    ///   that exists but cannot be read must not leave a tab behind either.
    /// - Returns: nil when nothing survived, so the caller leaves the window
    ///   in the shape it starts in.
    func rebuilt(isOpen: (String) -> Bool) -> Rebuilt? {
        var activeID: EditorGroup.ID?
        var hasFile = false
        guard var tree = Self.build(root, isOpen: isOpen, activeID: &activeID, hasFile: &hasFile)
        else { return nil }
        guard hasFile else { return nil }

        /// Invariant 1 of `EditorGroupTree`, restated over a file: a tree
        /// with no host has no way back to the shell. The saved grid always
        /// names one, so this answers a file written by another build or
        /// edited by hand.
        tree.ensureTerminalHost()

        let active = activeID.flatMap { tree.group($0) != nil ? $0 : nil }
        return Rebuilt(
            tree: tree,
            activeGroupID: active ?? tree.terminalHost ?? tree.groupIDs[0])
    }

    /// - Returns: the subtree, or nil when every cell under it was vacant.
    private static func build(
        _ node: Node,
        isOpen: (String) -> Bool,
        activeID: inout EditorGroup.ID?,
        hasFile: inout Bool
    ) -> EditorGroupTree? {
        switch node {
        case .leaf(let cell):
            let files = cell.files.filter { isOpen($0.path) }
            guard !files.isEmpty || cell.hostsTerminal else { return nil }

            /// `adopt` rather than `open`, because what is being put back is
            /// the tab and not a fresh one over the same path: it inserts
            /// into the run its own pin puts it in, so replaying the saved
            /// order reproduces the bar, pinned tabs at the head.
            var tabs = EditorTabSet()
            for file in files {
                tabs.adopt(EditorTab(path: file.path, isPinned: file.isPinned))
            }

            /// Adopting leaves the last tab selected. The saved selection
            /// wins when its file came back; failing that, a cell that hosts
            /// the terminal shows it, and a cell that does not keeps the
            /// file it landed on — showing a terminal it does not have would
            /// draw an empty pane.
            if let selected = cell.selectedFile, files.contains(where: { $0.path == selected }) {
                tabs.select(selected)
            } else if cell.hostsTerminal {
                tabs.selectTerminal()
            }

            let group = EditorGroup(tabs: tabs, hostsTerminal: cell.hostsTerminal)
            if cell.isActive { activeID = group.id }
            if !files.isEmpty { hasFile = true }
            return .leaf(group)

        case .split(let split):
            let first = build(split.first, isOpen: isOpen, activeID: &activeID, hasFile: &hasFile)
            let second = build(split.second, isOpen: isOpen, activeID: &activeID, hasFile: &hasFile)

            switch (first, second) {
            case (nil, nil):
                return nil
            case (let survivor?, nil), (nil, let survivor?):
                return survivor
            case (let first?, let second?):
                return .split(EditorGroupTree.Split(
                    direction: split.direction,
                    ratio: split.ratio,
                    first: first,
                    second: second))
            }
        }
    }
}

// MARK: Node Codable

/// Spelled out rather than synthesized, so the file reads as `cell` and
/// `split` keys instead of the `_0` a synthesized enum writes — the same
/// shape, and for the same reason, as `SplitTree.Node`.
extension EditorGridState.Node: Codable {
    enum CodingKeys: String, CodingKey {
        case cell
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.cell) {
            self = .leaf(try container.decode(EditorGridState.Cell.self, forKey: .cell))
        } else if container.contains(.split) {
            self = .split(try container.decode(EditorGridState.Split.self, forKey: .split))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Editor grid node is neither a cell nor a split"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .leaf(let cell):
            try container.encode(cell, forKey: .cell)
        case .split(let split):
            try container.encode(split, forKey: .split)
        }
    }
}
