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

    static func provider(for item: EditorCenter.DragItem) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = Data(text(for: item).utf8)
        /// Own-process only: this names a tab inside this window, and nothing
        /// outside the app could act on it.
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(payload, nil)
            return nil
        }
        WindowBreadcrumbs.note("tab drag: began \(text(for: item))")
        return provider
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

    func show(_ zone: EditorDropZone?) {
        guard self.zone != zone else { return }
        self.zone = zone
        watch()
    }

    /// A drag whose session ends without a callback to this cell.
    ///
    /// `performDrop` and `dropExited` cover the two ordinary endings, and a
    /// cancelled session — the pointer lifting over the cell it started in,
    /// which is the reader taking a tab back — reaches neither. The mouse
    /// button is the ground truth: no button down, no drag, so nothing may
    /// still be highlighted. `pressedMouseButtons` is non-zero for the whole
    /// of a real drag, so this cannot clear one that is still live.
    private var watchdog: Timer?

    private func watch() {
        watchdog?.invalidate()
        watchdog = nil
        guard zone != nil else { return }

        watchdog = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons == 0 else { return }
            timer.invalidate()
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watchdog = nil
                self.zone = nil
            }
        }
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

    func dropEntered(info: DropInfo) {
        WindowBreadcrumbs.note(
            "tab drag: entered \(label) at "
            + "\(Int(info.location.x)),\(Int(info.location.y)) "
            + "size=\(Int(size.width))x\(Int(size.height)) bar=\(Int(barHeight)) "
            + "zone=\(resolve(info))")
        state.show(resolve(info))
    }

    /// No proposal of its own, deliberately.
    ///
    /// This returned `DropProposal(operation: .move)`, which reads as the
    /// truth — the tab leaves the cell it came from — and cost the gesture
    /// its drop: a destination may only propose an operation the *source*
    /// allows, and the session `.onDrag` opens allows a copy. Proposing a
    /// move it never offered had AppKit refuse the drop with no error and no
    /// callback, so the tab flew back and nothing happened. Nil takes the
    /// default proposal, which is by construction one the source allows.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        state.show(resolve(info))
        return nil
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
