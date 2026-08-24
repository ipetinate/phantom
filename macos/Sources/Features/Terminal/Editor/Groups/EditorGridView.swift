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
            /// Identified by the cell it draws, and that is load-bearing.
            /// Without it SwiftUI matches these views by position when the
            /// grid reshapes, and a cell's `@State` outlives the cell — which
            /// is how a drop that collapsed one pane left the other wearing
            /// the drop panel with nothing being dragged.
            .id(group.id)

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

    /// Where a drag hovering over this cell would put the tab. Per cell, so
    /// two cells can never both be lit.
    ///
    /// `@State` holding an object, not `@StateObject`: `@State` keeps the
    /// instance alive for the cell's lifetime without subscribing to it, so a
    /// zone written from a drag callback does **not** re-run this body. That
    /// matters because this body builds the drop target — see
    /// `EditorCellDropState` for the enter/leave storm it caused when it did.
    @State private var drop = EditorCellDropState()

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                EditorPaneTabBar(
                    center: center,
                    groupID: group.id,
                    terminalDirectory: terminalDirectory
                )
                .background(coat)
                surface
            }
            /// The drop region goes **over** the cell's content, not under it.
            ///
            /// Attached to the stack itself it sat below the surface, and the
            /// surface is an AppKit view — the editor's text view, or the
            /// terminal. A real subview wins the pointer over a SwiftUI drop
            /// region beneath it, so the region kept being exited the moment
            /// the pointer crossed onto the document. The breadcrumbs from a
            /// reader's drag showed it exactly: `entered` and `left`, over and
            /// over, and the only two places a highlight ever appeared were
            /// the tab bar and the strip of minimap on the right — the two
            /// parts of the cell the text view does not cover.
            ///
            /// A clear layer with a `contentShape`, so it is a shape the drag
            /// can find. It answers for one private type, so a file dragged in
            /// from the Finder still reaches whatever wanted it, and it takes
            /// no mouse events of its own.
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [EditorTabDrag.type],
                        delegate: EditorCellDropDelegate(
                            size: geometry.size,
                            barHeight: center.showsTabBar(in: group.id)
                                ? EditorTabBar.height : 0,
                            state: drop,
                            perform: { item, zone in
                                center.drop(item, on: group.id, zone: zone)
                            },
                            label: cellLabel
                        )
                    )
            }
            .overlay(alignment: .topLeading) {
                EditorCellDropHighlight(state: drop, size: geometry.size)
            }
        }
    }

    /// How this cell is named in the breadcrumbs. A log that says only "a
    /// cell" cannot tell two of them apart, which is exactly the question a
    /// drag that went to the wrong half raises.
    private var cellLabel: String {
        if center.hostsTerminal(group.id) { return "terminal cell" }
        let name = group.tabs.selectedPath.map { ($0 as NSString).lastPathComponent }
        return "cell(\(name ?? "empty"))"
    }

    /// The coat behind this cell's own drawing: the terminal's background
    /// colour at its configured opacity, which is what the sidebar and the
    /// titlebar filler paint too.
    ///
    /// Translucent on purpose — the window under it is transparent in the
    /// blur and glass modes, and an opaque fill here is a slab that ignores
    /// both. `Color.clear` while the surface has not answered yet.
    private var coat: Color {
        center.paneBackground.map(Color.init(nsColor:)) ?? .clear
    }

    /// The cell's content, coated except where the terminal is.
    ///
    /// The terminal paints that same translucent colour itself, over the
    /// window: a coat underneath it composites twice and comes out darker
    /// than the file cell beside it — measured at `#08080a` against
    /// `#0d0d10`. The bar above it still takes one, because nothing else
    /// paints there.
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
            .background(coat)
        }
    }
}

/// The shape an arriving tab would take, drawn over one cell: a blurred
/// panel, a hairline ring in the theme's accent, and a word for what the drop
/// will do.
///
/// Its own view, and the only thing that observes the drag state. The cell
/// around it builds the drop target, so a highlight that re-ran the cell's
/// body rebuilt that target on every pointer move — see
/// `EditorCellDropState`.
///
/// Blurred rather than tinted. A translucent wash over a terminal full of
/// output left the text legible underneath and the panel looking like a
/// stain; a material makes the region read as a *destination* — the content
/// behind it is still placed, but plainly not the subject.
///
/// Edge to edge, with only the corners rounded. Inset by a few points it left
/// a frame of bare window showing on all four sides, which read as the panel
/// being broken rather than as a margin.
///
/// Hit testing off: this sits above the cell while a drag is in flight, and a
/// view that answered the pointer here would take the drop away from the
/// delegate underneath it.
private struct EditorCellDropHighlight: View {
    @ObservedObject var state: EditorCellDropState
    let size: CGSize

    @ObservedObject private var palette: ThemePalette = .shared

    var body: some View {
        Group {
            if let zone = state.zone {
                let rect = zone.highlight(in: size)
                let accent = palette.accent ?? .accentColor
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(accent.opacity(0.85), lineWidth: 1)
                    }
                    .overlay { label(for: zone, accent: accent) }
                    .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: state.zone)
    }

    /// What the drop will do, said in the destination it will do it to.
    ///
    /// Two answers, because there are two: the centre and the bar take the tab
    /// into this cell, an edge makes a cell of its own. Naming the outcome
    /// beats naming the gesture — the reader already knows they are dragging.
    private func label(for zone: EditorDropZone, accent: Color) -> some View {
        let isMove = zone == .center
        return HStack(spacing: 6) {
            Image(systemName: isMove ? "arrow.down.right.square" : "rectangle.split.2x1")
                .font(.system(size: 11, weight: .semibold))
            Text(isMove ? "Move here" : "Split here")
                .font(palette.font(size: 11, weight: .semibold))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 1)
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
