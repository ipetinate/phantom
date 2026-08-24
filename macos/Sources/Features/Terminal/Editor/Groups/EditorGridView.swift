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

    /// Watched only to know whether a drag is in flight, which is two events
    /// per drag — the begin and the end. Nothing here reacts to the pointer
    /// moving, which is the thing that must not re-run this body.
    @ObservedObject private var dragSession: EditorTabDragSession = .shared

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
                    .overlay { catcher(in: geometry.size) }
            }
            /// Behind the cell's content, which is where the terminal's own
            /// splits put theirs — see `TerminalSplitTreeView`.
            ///
            /// It was an overlay for one build, to get the region out from
            /// under the editor's text view, and that was the wrong fix twice
            /// over: a clear layer with a shape takes every click under it, so
            /// it swallowed the tabs' own gestures and the tabs stopped being
            /// draggable at all. And the region was never the problem — the
            /// operation mask was. A drag begun by `.onDrag` allows a copy
            /// only, so a cell proposing a move was refused, and what the
            /// breadcrumbs recorded as enter-and-leave was that refusal. The
            /// session is AppKit's now and answers `.move`, which is the
            /// arrangement the terminal's splits have always used with the
            /// region in the background.
            .background {
                Color.clear
                    .onDrop(
                        of: [EditorTabDrag.type],
                        delegate: EditorCellDropDelegate(
                            size: geometry.size,
                            barHeight: barHeight,
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

    /// A drop region over the surface, present only while a tab is in flight.
    ///
    /// The region in the cell's background is enough almost everywhere, and
    /// for the terminal it is not: a Metal-backed `NSView` is a real subview
    /// above it, and a drag over the shell never reached the cell underneath.
    /// The editor's text view lets it through; the terminal does not.
    ///
    /// Above the surface and *only during a drag*, which is what makes it
    /// safe. A clear layer with a shape takes every click under it — that is
    /// how an earlier version of this cost the tabs their own gestures — and
    /// there are no clicks to take while the pointer is holding a tab.
    ///
    /// Over the surface rather than the whole cell, so the tab bar keeps its
    /// own gestures either way, and the geometry is the surface's: the bar is
    /// not under this layer, so it has no height to subtract.
    @ViewBuilder
    private func catcher(in cell: CGSize) -> some View {
        if dragSession.item != nil {
            Color.clear
                .contentShape(Rectangle())
                .onDrop(
                    of: [EditorTabDrag.type],
                    delegate: EditorCellDropDelegate(
                        size: CGSize(
                            width: cell.width,
                            height: max(cell.height - barHeight, 0)),
                        barHeight: 0,
                        state: drop,
                        perform: { item, zone in
                            center.drop(item, on: group.id, zone: zone)
                        },
                        label: cellLabel
                    )
                )
        }
    }

    /// How tall this cell's bar is, or zero when it has none. Asked of the
    /// centre so the drop regions and the bar itself cannot disagree.
    private var barHeight: CGFloat {
        center.showsTabBar(in: group.id) ? EditorTabBar.height : 0
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

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.terminal = terminal
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        host.terminal = terminal
        host.adopt()
    }
}

/// The host, which can also rescue a terminal that has been orphaned.
///
/// Moving the terminal to another cell tears down the host it was in and
/// builds one in the cell it goes to, and the order of those two is SwiftUI's
/// to choose. When the teardown lands *after* the new host has already
/// updated, the old host takes the terminal down with it and nothing asks
/// again: the cell showed an empty frame with the window's blur through it,
/// and the keys went to whatever held focus instead — which is how it was
/// reported.
///
/// So the adoption is not only done on update. Every layout pass checks
/// whether the terminal has a superview at all and takes it back when it does
/// not. Only when it is orphaned, deliberately: a stale host that stole a
/// live one would be the same bug with the cells swapped.
private final class TerminalHostView: NSView {
    weak var terminal: NSView?

    override func layout() {
        super.layout()
        guard let terminal else { return }

        /// A host on its way out does not claim anything: it has already left
        /// the window, and the only thing it could do is take the terminal
        /// back off the cell that now owns it.
        guard window != nil else { return }

        /// Parked anywhere that is not this host — orphaned, or still inside
        /// the host of a cell that has since collapsed. The second case is
        /// what was missing: adoption only rescued an orphan, so a terminal
        /// left in a stale host kept that host's size while the live cell grew
        /// around it, and the part of the cell the surface no longer covered
        /// was a hole straight through to the desktop. It happened while
        /// moving a tab between two *other* cells, which is why it looked like
        /// the terminal had lost its background on its own.
        guard terminal.superview === self else {
            adopt()
            return
        }

        /// The frame is set here as well as on adoption, and this is the half
        /// that matters. A host adopts before it has been laid out, so at that
        /// moment `bounds` is zero — and an autoresizing mask resizes a frame
        /// *proportionally*, so a frame that starts at zero stays at zero
        /// through every resize after it. The terminal was in the hierarchy
        /// with nothing to draw into, which is a transparent pane showing the
        /// desktop through the window, and it came back only when switching
        /// tabs built the host again with a size already known.
        guard terminal.frame != bounds else { return }
        terminal.frame = bounds
    }

    func adopt() {
        guard let terminal, terminal.superview !== self else { return }

        /// Focus travels with the view. The terminal is only first responder
        /// while the reader is typing in it, and a move that dropped that on
        /// the floor sent the next keystroke somewhere else.
        let responder = window?.firstResponder as? NSView
        let wasFocused = responder.map { $0 === terminal || $0.isDescendant(of: terminal) } ?? false

        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)

        if wasFocused, let responder {
            window?.makeFirstResponder(responder)
        }
    }
}
