import AppKit
import SwiftUI

/// The editor's cells on screen: `EditorGroupTree`, drawn.
///
/// One hosting view holds the whole right-hand pane now — every cell's tab
/// bar, every cell's surface, and the terminal among them. What used to be
/// two sibling views toggled by `isHidden` is a tree the reader can divide,
/// and the thing that decides what is visible is the tree rather than the
/// controller.
struct EditorGridView: View {
    @ObservedObject var center: EditorCenter
    @ObservedObject var terminalDirectory: EditorTerminalDirectory
    @ObservedObject var search: WorkspaceSearchCenter

    /// The window's one terminal, handed in rather than built.
    ///
    /// It owns a live pty, so a second instance would be a second shell.
    /// Moving it between cells is re-parenting this exact view — see
    /// `TerminalCellHost`.
    let terminal: NSView

    var body: some View {
        EditorGridNode(
            node: center.tree,
            center: center,
            terminalDirectory: terminalDirectory,
            search: search,
            terminal: terminal
        )
    }
}

/// One node of the grid, which draws either a cell or a division and recurses
/// into itself.
///
/// A named view rather than a `@ViewBuilder` function, because a function
/// returning `some View` that calls itself has no finite type — the same
/// reason `TerminalSplitSubtreeView` exists beside the terminal's splits.
private struct EditorGridNode: View {
    let node: EditorGroupTree
    @ObservedObject var center: EditorCenter
    @ObservedObject var terminalDirectory: EditorTerminalDirectory
    @ObservedObject var search: WorkspaceSearchCenter
    let terminal: NSView

    var body: some View {
        switch node {
        case .leaf(let group):
            EditorGridCell(
                group: group,
                center: center,
                terminalDirectory: terminalDirectory,
                search: search,
                terminal: terminal
            )

        case .split(let split):
            SplitView(
                split.direction,
                Binding(
                    get: { split.ratio },
                    set: { center.setRatio($0, forSplit: split.id) }
                ),
                /// The editor's dividers have no surface configuration to ask
                /// for a colour, so their Default-mode fallback is the system
                /// separator. The mode itself — hidden, themed, custom — is
                /// resolved inside `SplitView`, which is why every divider in
                /// the window answers the one setting.
                systemDividerColor: Color(nsColor: .separatorColor),
                left: {
                    EditorGridNode(
                        node: split.first, center: center,
                        terminalDirectory: terminalDirectory,
                        search: search, terminal: terminal)
                },
                right: {
                    EditorGridNode(
                        node: split.second, center: center,
                        terminalDirectory: terminalDirectory,
                        search: search, terminal: terminal)
                },
                onEqualize: { center.setRatio(0.5, forSplit: split.id) }
            )
        }
    }
}

/// One cell: its own bar of tabs, and whichever surface that bar has selected.
///
/// The bar is a sibling above the surface rather than a strip over it, which
/// is what retires the inset the pane used to push the terminal's content
/// down by — there is nothing to compensate for when the two do not overlap.
private struct EditorGridCell: View {
    let group: EditorGroup
    @ObservedObject var center: EditorCenter
    @ObservedObject var terminalDirectory: EditorTerminalDirectory
    @ObservedObject var search: WorkspaceSearchCenter
    let terminal: NSView

    @ObservedObject private var palette: ThemePalette = .shared

    /// Where a drag hovering over this cell would put the tab, and nil when
    /// nothing is over it. Per cell, so two cells can never both be lit.
    @State private var dropZone: EditorDropZone?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                EditorPaneTabBar(
                    center: center,
                    groupID: group.id,
                    terminalDirectory: terminalDirectory
                )
                surface
            }
            .overlay(alignment: .topLeading) { highlight(in: geometry.size) }
            /// Cleared whenever the grid changes shape, which a completed
            /// drop always does. `dropExited` covers a drag that leaves the
            /// cell, but a session that dies mid-flight — the pointer never
            /// lifting inside any cell — would otherwise leave the wash
            /// painted over a pane nobody is dragging onto.
            .onChange(of: center.tree) { _ in dropZone = nil }
            .onDrop(
                of: [.plainText, .text],
                delegate: EditorCellDropDelegate(
                    size: geometry.size,
                    zone: { dropZone = $0 },
                    perform: { item, zone in
                        center.drop(item, on: group.id, zone: zone)
                    }
                )
            )
        }
    }

    /// The shape the arriving tab would take, drawn over the cell.
    ///
    /// Hit testing off: the highlight sits above the cell while a drag is in
    /// flight, and a view that answered the pointer there would take the drop
    /// away from the delegate underneath it.
    @ViewBuilder
    private func highlight(in size: CGSize) -> some View {
        if let dropZone {
            let rect = dropZone.highlight(in: size)
            let accent = palette.accent ?? .accentColor
            Rectangle()
                .fill(accent.opacity(0.22))
                .overlay(Rectangle().strokeBorder(accent.opacity(0.7), lineWidth: 2))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var surface: some View {
        if group.tabs.showsTerminal {
            TerminalCellHost(terminal: terminal)
        } else {
            EditorPaneView(
                center: center,
                groupID: group.id,
                terminalDirectory: terminalDirectory,
                search: search
            )
        }
    }
}

/// Puts the window's one terminal inside whichever cell is showing it.
///
/// SwiftUI owns only the empty host this makes; the terminal is moved into
/// it. Returning the terminal itself from `makeNSView` would hand SwiftUI a
/// view it may discard, and discarding that one takes the shell off the
/// screen — AppKit re-parents a view without disturbing what is inside it,
/// which is how the terminal's own splits already move surfaces around.
///
/// Pinned with an autoresizing mask rather than constraints, deliberately: a
/// move would otherwise mean deactivating the old cell's constraints and
/// activating new ones, and a constraint left behind between views that no
/// longer share an ancestor raises — which in this window means the app runs
/// on with nothing on screen.
private struct TerminalCellHost: NSViewRepresentable {
    let terminal: NSView

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        guard terminal.superview !== host else { return }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.frame = host.bounds
        terminal.autoresizingMask = [.width, .height]
        host.addSubview(terminal)
    }
}
