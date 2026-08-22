import AppKit
import SwiftUI

/// An SVG's markup, decoded into something drawable.
///
/// A separate type from the pane below so the interesting half is a function
/// of a string: what counts as drawable is the whole question here, and a
/// wrong answer shows up as a blank pane rather than as a crash.
enum EditorSVGImage {
    /// Nil for markup that does not describe a picture.
    ///
    /// Two failures rather than one, and the second is the one worth having.
    /// AppKit refuses outright text that is not markup at all — a truncated
    /// tag, an empty buffer, a `.svg` that turns out to be HTML. But `<svg/>`
    /// with no dimensions and nothing in it *succeeds*, handing back an image
    /// that reports a size of zero, and drawing that gives a pane with
    /// nothing in it and no explanation. Refusing it here is what turns that
    /// into a sentence the reader can act on.
    static func decode(_ text: String) -> NSImage? {
        guard let image = NSImage(data: Data(text.utf8)) else { return nil }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }
}

/// The SVG, drawn.
///
/// Drawn from the buffer rather than from the file, so the picture is of the
/// document as it stands and not of the last thing that was saved. The toggle
/// exists to read one file two ways; a pane a save behind would be answering
/// about a different one.
struct EditorSVGPane: View {
    let text: String
    let background: NSColor

    /// Decoded into state rather than in `body`, keyed on the text.
    ///
    /// `body` runs whenever anything it observes changes, and parsing a
    /// megabyte of vector map data on each of those passes is work nobody
    /// asked for. Keying the task on the text means it happens once per
    /// version of the file.
    @State private var decoded: Decoded = .undecided

    private enum Decoded {
        /// Before the first pass. Distinct from failure so the frame between
        /// appearing and decoding draws the background rather than flashing a
        /// message that is about to be wrong.
        case undecided
        case drawable(NSImage)
        case unreadable
    }

    var body: some View {
        ZStack {
            Color(nsColor: background)

            switch decoded {
            case .drawable(let image):
                /// Fitted, and no zoom. The step is dropped rather than
                /// handled because handling it is only half a feature: the
                /// percentage readout and the buttons that go with it live in
                /// the media pane, and a picture that silently drifts to 400%
                /// with nothing on screen saying so is worse than one that
                /// stays where it was put. A reader who wants to zoom an SVG
                /// wants it in the viewer that has the controls.
                ImageViewerView(image: image, level: .fit, onZoomStep: { _ in })

            case .unreadable:
                MediaUnreadableView(message: "Couldn't draw this SVG. Its markup may be incomplete.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .undecided:
                Color.clear
            }
        }
        .task(id: text) {
            decoded = EditorSVGImage.decode(text).map(Decoded.drawable) ?? .unreadable
        }
    }
}
