import SwiftUI
import UniformTypeIdentifiers

/// What a dragged tab carries, written as text.
///
/// Text rather than a custom transferable type: a drag leaves SwiftUI's own
/// world and comes back through an `NSItemProvider`, and plain text is the
/// one representation that survives that round trip without a registered
/// type identifier. The prefix keeps it from being mistaken for a file path
/// dragged in from the Finder — a drop that could not be decoded is one this
/// grid refuses rather than guesses at.
enum EditorTabDrag {
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
        NSItemProvider(object: text(for: item) as NSString)
    }
}

/// Where a drag over one cell would land, and the highlight that says so.
///
/// The zone comes from `EditorDropZone.resolve`, which is tested on its own,
/// so what is left here is the part only a view can do: report the pointer's
/// position while it moves, and paint the half of the cell the tab would take.
struct EditorCellDropDelegate: DropDelegate {
    let size: CGSize

    /// Written on every move, so the highlight follows the pointer between
    /// the centre and the four edges rather than latching on entry.
    let zone: (EditorDropZone?) -> Void

    let perform: (EditorCenter.DragItem, EditorDropZone) -> Void

    func dropEntered(info: DropInfo) {
        zone(resolve(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone(resolve(info))
        /// A move, not a copy: the tab leaves the cell it came from. The
        /// cursor says so, and saying "copy" would promise a second tab this
        /// grid deliberately never makes.
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        zone(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = resolve(info)
        zone(nil)

        guard let provider = info.itemProviders(for: [.plainText, .text]).first
        else { return false }

        /// Loaded asynchronously because that is the only way an item
        /// provider hands anything over, and answered `true` before it
        /// arrives: the answer is whether this cell accepts the drag, which
        /// is already known.
        let apply = perform
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String,
                  let item = EditorTabDrag.item(from: text)
            else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { apply(item, target) }
            }
        }
        return true
    }

    private func resolve(_ info: DropInfo) -> EditorDropZone {
        EditorDropZone.resolve(point: info.location, in: size)
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
