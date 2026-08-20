import AppKit
import SwiftUI

/// An image, fitted to the pane.
struct ImageViewerView: View {
    let url: URL

    @State private var image: NSImage?
    @State private var attempted = false

    var body: some View {
        Group {
            if let image {
                FittedImageView(image: image)
            } else if attempted {
                MediaUnreadableView(message: "Couldn't read this image.")
            } else {
                /// One body evaluation before `onAppear` runs. Clear rather
                /// than a spinner: reading a local file is not a wait.
                Color.clear
            }
        }
        /// Loaded in the view, not in `MediaDocument`: the document stays a
        /// decision and the view is what touches the disk. It also puts the
        /// failure where it reads best, in the pane instead of an alert.
        .onAppear {
            image = NSImage(contentsOf: url)
            attempted = true
        }
    }
}

/// `NSImageView` rather than SwiftUI's `Image(nsImage:)`, for two behaviours
/// that are one property each here.
///
/// `scaleProportionallyDown` fits a 4000px screenshot to the pane while
/// leaving a 16px favicon at 16px, instead of blowing it up into a blurry
/// wall. And `animates` makes a GIF move — SwiftUI's `Image` holds still,
/// which reads as a broken file.
private struct FittedImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.animates = true
        view.image = image
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = image
    }
}
