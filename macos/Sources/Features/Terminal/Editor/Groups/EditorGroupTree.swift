import CoreGraphics
import Foundation

/// How the editor's cells are arranged: a binary tree of splits with a group
/// at every leaf.
///
/// A tree rather than a grid of rows and columns. The layout asked for is a
/// free one — 1x1, 1x2, 2x2, 2x3, 3x3, "tanto faz" — and a binary tree
/// expresses all of those *and* their asymmetric cousins (one tall cell
/// beside two short ones), with no dimension to cap and no empty slots to
/// reason about. It is also the shape the terminal's own splits already use,
/// so direction, ratio and leaf mean here what they mean elsewhere in this
/// codebase.
///
/// Deliberately not `SplitTree`, which is that shape for terminal surfaces:
/// it is constrained to `ViewType: NSView & Codable & Identifiable`, a group
/// is a value and not a view, and widening it would mean editing a file the
/// fork tracks from upstream.
///
/// Every mutation here leaves the tree well formed, so callers mutate a cell
/// and never carry the invariants themselves. The invariants, which is what
/// the tests are about:
///
/// 1. **Exactly one cell hosts the terminal.** It is a movable tab, so the
///    host changes; there is one terminal, so it can be in neither two cells
///    nor none — losing it would leave no way back to the shell.
/// 2. **No vacant leaf.** A cell with no files that does not host the
///    terminal is removed and its sibling takes the space.
///
/// A single-cell tree is the floor: the last cell is never removed. It also
/// cannot be vacant in a well-formed tree, because with one cell that cell
/// is the terminal's host.
indirect enum EditorGroupTree: Equatable {
    case leaf(EditorGroup)
    case split(Split)

    /// One division: the two subtrees, which way they sit, and where the
    /// divider rests.
    struct Split: Equatable {
        /// Stable across ratio changes, so a view can key a dragging
        /// divider to a binding that survives the drag.
        let id: UUID

        var direction: SplitViewDirection

        /// The first side's share of the axis, 0...1 — the same meaning
        /// `SplitView` gives it, so the value passes straight through.
        var ratio: CGFloat

        var first: EditorGroupTree
        var second: EditorGroupTree

        init(
            id: UUID = UUID(),
            direction: SplitViewDirection,
            ratio: CGFloat = 0.5,
            first: EditorGroupTree,
            second: EditorGroupTree
        ) {
            self.id = id
            self.direction = direction
            self.ratio = Self.clamp(ratio)
            self.first = first
            self.second = second
        }

        /// Kept away from the ends, where a cell would be a sliver nobody
        /// asked for and no drag could recover.
        static func clamp(_ ratio: CGFloat) -> CGFloat {
            min(max(ratio, 0.1), 0.9)
        }
    }
}

// MARK: Reading

extension EditorGroupTree {
    /// Every cell, in the order they are laid out.
    var groups: [EditorGroup] {
        switch self {
        case .leaf(let group):
            return [group]
        case .split(let split):
            return split.first.groups + split.second.groups
        }
    }

    var groupIDs: [EditorGroup.ID] { groups.map(\.id) }

    func group(_ id: EditorGroup.ID) -> EditorGroup? {
        groups.first { $0.id == id }
    }

    /// The cell the terminal is in.
    ///
    /// Optional even though a well-formed tree always has one: a caller can
    /// assemble a tree by hand and be wrong, and answering `nil` beats
    /// trapping inside a view's body.
    var terminalHost: EditorGroup.ID? {
        groups.first(where: \.hostsTerminal)?.id
    }

    var hasUnsavedChanges: Bool {
        groups.contains { $0.tabs.hasUnsavedChanges }
    }

    /// Which cell has this file open, if any.
    ///
    /// The grid's version of the rule `EditorTabSet.open` already chose for
    /// one bar: a file that is already open is *revealed*, never opened
    /// twice. Two live editors over one file would need a shared buffer to
    /// be honest about saving, which is a different feature.
    func groupHolding(_ path: String) -> EditorGroup.ID? {
        groups.first { $0.holds(path) }?.id
    }

    /// Where focus should go when `id` disappears: the nearest cell on the
    /// other side of the split it was in.
    func neighbour(of id: EditorGroup.ID) -> EditorGroup.ID? {
        guard case .split(let split) = self else { return nil }

        if case .leaf(let group) = split.first, group.id == id {
            return split.second.groups.first?.id
        }
        if case .leaf(let group) = split.second, group.id == id {
            return split.first.groups.first?.id
        }
        return split.first.neighbour(of: id) ?? split.second.neighbour(of: id)
    }
}

// MARK: Mutating

extension EditorGroupTree {
    /// Changes one cell, then heals the tree.
    ///
    /// Healing is the reason this exists rather than callers reaching for a
    /// leaf: a change that empties a cell must not leave a hole in the grid,
    /// and every caller would otherwise have to remember that.
    mutating func update(_ id: EditorGroup.ID, _ body: (inout EditorGroup) -> Void) {
        apply(id, body)
        heal()
    }

    /// Splits the cell holding `id` in two and puts `newGroup` in the new
    /// half.
    ///
    /// - Parameter onFirstSide: whether the new cell takes the leading or
    ///   top half — which is what a drop on the left or top edge asks for.
    /// - Returns: whether the cell was found.
    @discardableResult
    mutating func split(
        _ id: EditorGroup.ID,
        direction: SplitViewDirection,
        inserting newGroup: EditorGroup,
        onFirstSide: Bool = false,
        ratio: CGFloat = 0.5
    ) -> Bool {
        switch self {
        case .leaf(let group):
            guard group.id == id else { return false }
            let incoming = EditorGroupTree.leaf(newGroup)
            let existing = EditorGroupTree.leaf(group)
            self = .split(Split(
                direction: direction,
                ratio: ratio,
                first: onFirstSide ? incoming : existing,
                second: onFirstSide ? existing : incoming))
            return true

        case .split(var split):
            defer { self = .split(split) }
            if split.first.split(
                id, direction: direction, inserting: newGroup,
                onFirstSide: onFirstSide, ratio: ratio) {
                return true
            }
            return split.second.split(
                id, direction: direction, inserting: newGroup,
                onFirstSide: onFirstSide, ratio: ratio)
        }
    }

    /// Removes a cell and gives its space to the sibling that shared its
    /// split.
    ///
    /// The terminal never goes with it: a cell that hosted the terminal
    /// hands it to the sibling taking its place, because there is no other
    /// way back to the shell. The sibling adopts it without *showing* it —
    /// closing a cell is not a request to look at the terminal, and the tab
    /// is then one click away in the sibling's bar.
    ///
    /// - Returns: whether anything was removed. The last cell is never
    ///   removed: the grid always has one.
    @discardableResult
    mutating func remove(_ id: EditorGroup.ID) -> Bool {
        guard case .split(var split) = self else { return false }

        for takingFirst in [true, false] {
            let side = takingFirst ? split.first : split.second
            guard case .leaf(let group) = side, group.id == id else { continue }
            var survivor = takingFirst ? split.second : split.first
            if group.hostsTerminal { survivor.adoptTerminal() }
            self = survivor
            return true
        }

        defer { self = .split(split) }
        if split.first.remove(id) { return true }
        return split.second.remove(id)
    }

    /// Moves the terminal to another cell — the drag this feature was asked
    /// for.
    ///
    /// The cell it lands in shows it, because dragging it somewhere is a
    /// request to see it there. The cell it left stops showing it and falls
    /// back to its last file; with no file to fall back to, that cell was
    /// only ever the terminal's frame and the heal removes it.
    mutating func moveTerminal(to id: EditorGroup.ID) {
        guard group(id) != nil, let host = terminalHost, host != id else { return }

        apply(host) { group in
            group.hostsTerminal = false
            guard group.tabs.showsTerminal, let last = group.tabs.tabs.last?.path else { return }
            group.tabs.select(last)
        }
        apply(id) { group in
            group.hostsTerminal = true
            group.tabs.selectTerminal()
        }
        heal()
    }

    /// Moves an open file to another cell, selecting it there.
    ///
    /// The tab travels whole — its pin and its dirty dot with it — because
    /// what the reader dragged is the tab and not its path. This used to
    /// close the path here and `open` it there, which built a *fresh* tab at
    /// the far end: a pinned tab landed unpinned in the middle of the bar,
    /// and a tab with unsaved edits landed with no dot on it.
    mutating func move(_ path: String, to id: EditorGroup.ID) {
        guard let source = groupHolding(path), source != id, group(id) != nil else { return }
        guard let tab = group(source)?.tabs.tab(for: path) else { return }

        apply(source) { $0.tabs.close(path) }
        apply(id) { $0.tabs.adopt(tab) }
        heal()
    }

    /// Opens a file in a cell, or reveals the cell that already has it.
    ///
    /// - Returns: the cell now showing the file, which is what the caller
    ///   points focus at.
    @discardableResult
    mutating func open(_ path: String, in id: EditorGroup.ID) -> EditorGroup.ID {
        if let existing = groupHolding(path) {
            apply(existing) { $0.tabs.select(path) }
            return existing
        }
        apply(id) { $0.tabs.open(path) }
        return id
    }

    /// Closes a file, and the cell with it when nothing is left to show.
    mutating func close(_ path: String, in id: EditorGroup.ID) {
        update(id) { $0.tabs.close(path) }
    }

    /// Closes every file in every cell, which leaves the grid as the one
    /// cell the terminal is in — the shape it starts in.
    mutating func closeAllFiles() {
        updateAll { $0.tabs.closeAll() }
        heal()
    }

    /// Gives the terminal to the first cell when a tree arrives without a
    /// host.
    ///
    /// Invariant 1 holds by construction for every tree this file builds, so
    /// nothing inside the app needs this. A tree assembled from the session
    /// file does not have that guarantee — it can be edited by hand, and it
    /// can be written by a build that recorded the host differently — and a
    /// tree with no host reaches the grid with no way back to the shell.
    mutating func ensureTerminalHost() {
        guard terminalHost == nil else { return }
        adoptTerminal()
    }

    /// Moves a divider. Addressed by the split's own id so a drag survives
    /// the tree changing shape around it.
    mutating func setRatio(_ ratio: CGFloat, forSplit id: UUID) {
        guard case .split(var split) = self else { return }
        defer { self = .split(split) }

        if split.id == id {
            split.ratio = Split.clamp(ratio)
            return
        }
        split.first.setRatio(ratio, forSplit: id)
        split.second.setRatio(ratio, forSplit: id)
    }
}

// MARK: Keeping the tree well formed

extension EditorGroupTree {
    /// Applies a change to one cell, without healing.
    ///
    /// Private because a caller that skips the heal can leave a hole in the
    /// grid; the operations above pair the two.
    private mutating func apply(
        _ id: EditorGroup.ID,
        _ body: (inout EditorGroup) -> Void
    ) {
        switch self {
        case .leaf(var group):
            guard group.id == id else { return }
            body(&group)
            self = .leaf(group)

        case .split(var split):
            split.first.apply(id, body)
            split.second.apply(id, body)
            self = .split(split)
        }
    }

    /// Applies a change to every cell, without healing.
    private mutating func updateAll(_ body: (inout EditorGroup) -> Void) {
        switch self {
        case .leaf(var group):
            body(&group)
            self = .leaf(group)

        case .split(var split):
            split.first.updateAll(body)
            split.second.updateAll(body)
            self = .split(split)
        }
    }

    /// Removes vacant cells, letting siblings take the space.
    ///
    /// Bottom-up, so a split whose halves both collapse resolves in one
    /// pass. A vacant *root* leaf is left alone — the grid always has a
    /// cell, and in a well-formed tree the only single cell is the
    /// terminal's host, which is never vacant.
    private mutating func heal() {
        guard case .split(var split) = self else { return }

        split.first.heal()
        split.second.heal()

        if case .leaf(let group) = split.first, group.isVacant {
            self = split.second
            return
        }
        if case .leaf(let group) = split.second, group.isVacant {
            self = split.first
            return
        }
        self = .split(split)
    }

    /// Hands the terminal to this subtree's first cell, which is what a
    /// collapse does when the cell that held it goes away. The adopting
    /// cell does not change what it is showing.
    private mutating func adoptTerminal() {
        guard let target = groups.first?.id else { return }
        apply(target) { $0.hostsTerminal = true }
    }
}
