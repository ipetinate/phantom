import Combine
import SwiftUI
import UniformTypeIdentifiers

/// What a dragged tab carries.
///
/// A short string, under a type of this app's own — see `type` for why the
/// type matters more than the payload. The tokens are prefixed so a drop
/// that cannot be decoded is one this grid refuses rather than guesses at.
enum EditorTabDrag {
    /// A drag type of our own rather than plain text.
    ///
    /// Plain text was the first attempt and it never arrived. The editor's
    /// `NSTextView` and the terminal surface both register for dragged text,
    /// and a drag is offered to the deepest view that accepts its type — so
    /// the cell underneath them was never asked, and a tab dropped anywhere
    /// useful did nothing. A type only the cell registers walks past both,
    /// because that search carries on up the view hierarchy until something
    /// accepts.
    ///
    /// Declared in `Ghostty-Info.plist` beside `ghosttySurfaceId`, which
    /// upstream exports for the same reason: dragging a terminal between
    /// splits is also a private gesture that must not be confused with text.
    static let type = UTType(exportedAs: "com.ipetinate.phantom.editorTab")

    private static let terminalToken = "phantom.tab:terminal"
    private static let filePrefix = "phantom.tab:file:"

    static func text(for item: EditorCenter.DragItem) -> String {
        switch item {
        case .terminal: return terminalToken
        case .file(let path): return filePrefix + path
        }
    }

    /// The item some dragged text names, or nil when it names none of ours.
    static func item(from text: String) -> EditorCenter.DragItem? {
        if text == terminalToken { return .terminal }
        guard text.hasPrefix(filePrefix) else { return nil }
        let path = String(text.dropFirst(filePrefix.count))
        return path.isEmpty ? nil : .file(path)
    }

}

/// The payload as a `Transferable`, which is how it reaches the pasteboard.
///
/// `Transferable` rather than an `NSItemProvider` built by hand, because the
/// repo already bridges one to AppKit — `pasteboardItem()` — and an AppKit
/// session is what the drag needs; see `EditorTabDragSource` for why.
extension EditorCenter.DragItem: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: EditorTabDrag.type) { item in
            Data(EditorTabDrag.text(for: item).utf8)
        } importing: { data in
            guard let text = String(data: data, encoding: .utf8),
                  let item = EditorTabDrag.item(from: text)
            else { throw EditorTabDrag.PayloadError.unreadable }
            return item
        }
    }
}

extension EditorTabDrag {
    enum PayloadError: Error {
        /// A drop carrying our type whose bytes are not one of our tokens.
        /// Refused rather than guessed at.
        case unreadable
    }
}

/// Where a drag hovering over one cell would land.
///
/// A reference type, and that is the whole point. This held SwiftUI `@State`
/// in the cell, and writing it from a drag callback re-ran the cell's body —
/// which handed `.onDrop` a freshly built delegate, which SwiftUI registered
/// as a new drop target, which fired `dropExited` and then `dropEntered`. The
/// breadcrumbs from a single drag read as dozens of enter/leave pairs, one per
/// pointer move, because the highlight was rebuilding the thing that draws it.
///
/// What the reader saw was that loop: a panel that flickered while they aimed,
/// nothing at all when the race settled on the exit, and a panel left painted
/// over a cell when it settled on the entry with the drag already over.
///
/// Held by the cell in `@State` — which stores an object without subscribing
/// to it — so only the small view that draws the highlight observes this, and
/// the cell that owns the drop target never rebuilds while a drag is in
/// flight.
@MainActor
final class EditorCellDropState: ObservableObject {
    @Published private(set) var zone: EditorDropZone?

    /// Cleared the moment the session ends, however it ended.
    ///
    /// `performDrop` and `dropExited` cover the two ordinary endings; a
    /// release over the cell the drag started in reaches neither, and that is
    /// the reader taking a tab back. The session reports every ending there
    /// is — the reason the drag is an AppKit session — so no cell has to
    /// guess from the mouse button whether one is still in flight.
    private var sessionEnded: AnyCancellable?

    init(session: EditorTabDragSession = .shared) {
        sessionEnded = session.$item
            .filter { $0 == nil }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.zone = nil }
            }
    }

    func show(_ zone: EditorDropZone?) {
        guard self.zone != zone else { return }
        self.zone = zone
    }
}

/// Where a drag over one cell would land, and the highlight that says so.
///
/// The zone comes from `EditorDropZone.resolve`, which is tested on its own,
/// so what is left here is the part only a view can do: report the pointer's
/// position while it moves, and paint the half of the cell the tab would take.
struct EditorCellDropDelegate: DropDelegate {
    /// Named here as well so the delegate reads it without reaching across
    /// files for a type it uses in three places.
    static let dragType = EditorTabDrag.type

    let size: CGSize

    /// How tall this cell's bar is, or zero when it has none. The bar is a
    /// join rather than a top edge — see `EditorDropZone.resolve`.
    let barHeight: CGFloat

    /// Written on every move, so the highlight follows the pointer between
    /// the centre and the four edges rather than latching on entry.
    ///
    /// The object rather than a closure over view state: see
    /// `EditorCellDropState` for what writing view state from here cost.
    let state: EditorCellDropState

    let perform: (EditorCenter.DragItem, EditorDropZone) -> Void

    /// Which cell this is, for the breadcrumbs only — a drag that goes wrong
    /// goes wrong *somewhere*, and "a cell" was not enough to tell two of
    /// them apart in a log.
    let label: String

    /// Only ours. Asked because the terminal's splits ask it, and for the
    /// same reason: a drag of anything else must be left alone to reach
    /// whatever wanted it.
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [Self.dragType])
    }

    func dropEntered(info: DropInfo) {
        WindowBreadcrumbs.note(
            "tab drag: entered \(label) at "
            + "\(Int(info.location.x)),\(Int(info.location.y)) "
            + "size=\(Int(size.width))x\(Int(size.height)) bar=\(Int(barHeight)) "
            + "zone=\(resolve(info))")
        state.show(resolve(info))
    }

    /// A move, which is the truth: the tab leaves the cell it came from.
    ///
    /// This proposed a move once before and cost the gesture its drop — a
    /// destination may only propose an operation the *source* allows, and
    /// SwiftUI's `.onDrag` allows a copy, so AppKit refused with no error and
    /// no callback. The answer was not to stop proposing a move; it was to
    /// begin the session by hand and answer `.move` from the source, which is
    /// what the terminal's splits have always done.
    ///
    /// Guarded on the state the way the terminal's splits are: `dropUpdated`
    /// arrives once more *after* `performDrop`, and taking it would paint the
    /// panel back on over a grid that has already changed.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard state.zone != nil else { return DropProposal(operation: .forbidden) }

        let zone = resolve(info)

        /// Noted on a change only. Every pointer move calls this, so logging
        /// each one buries the drag in its own trace — and what a report needs
        /// is where the answer changed, which is also the only thing the
        /// reader sees.
        if zone != state.zone {
            WindowBreadcrumbs.note(
                "tab drag: over \(label) at "
                + "\(Int(info.location.x)),\(Int(info.location.y)) zone=\(zone)")
        }

        state.show(zone)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        WindowBreadcrumbs.note("tab drag: left \(label)")
        state.show(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = resolve(info)
        state.show(nil)

        guard let provider = info.itemProviders(for: [Self.dragType]).first else {
            WindowBreadcrumbs.note("tab drag: dropped with no provider of our type")
            return false
        }
        WindowBreadcrumbs.note("tab drag: dropped on \(label), zone=\(target)")

        /// Loaded asynchronously because that is the only way an item
        /// provider hands anything over, and answered `true` before it
        /// arrives: the answer is whether this cell accepts the drag, which
        /// is already known.
        let apply = perform
        provider.loadDataRepresentation(
            forTypeIdentifier: Self.dragType.identifier
        ) { data, _ in
            guard let data,
                  let text = String(data: data, encoding: .utf8),
                  let item = EditorTabDrag.item(from: text)
            else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { apply(item, target) }
            }
        }
        return true
    }

    /// The zone last reported for this cell is read from `state`, which is
    /// what the hysteresis in `EditorDropZone.resolve` holds on to. Kept
    /// there rather than here because a delegate is a value SwiftUI rebuilds
    /// on every update, so anything it remembered itself would be forgotten
    /// between two moves of the pointer.
    private func resolve(_ info: DropInfo) -> EditorDropZone {
        EditorDropZone.resolve(
            point: info.location,
            in: size,
            barHeight: barHeight,
            current: state.zone)
    }
}

extension EditorDropZone {
    /// The part of a cell this zone would fill, which is what the highlight
    /// draws: the whole cell for a move into it, and the half a split would
    /// give the arriving tab.
    ///
    /// Showing the destination rather than the divider is deliberate — a line
    /// where the split will fall says less than the shape the tab is about to
    /// occupy, and it is the convention every editor with this gesture uses.
    func highlight(in size: CGSize) -> CGRect {
        switch self {
        case .center:
            return CGRect(origin: .zero, size: size)
        case .leading:
            return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .trailing:
            return CGRect(
                x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top:
            return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom:
            return CGRect(
                x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}
