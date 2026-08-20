import AppKit
import SwiftUI

/// The pane a media tab draws: the editor's own background, and the viewer for
/// whichever kind this is.
///
/// Outside `Editor/Engine/` deliberately — `PDFKit` is not in the import set
/// that `EditorEngineBoundaryTests` allows the engine, and the Markdown
/// preview sits out here for the same reason.
struct MediaPaneView: View {
    let document: MediaDocument
    let theme: CodeTheme

    var body: some View {
        ZStack {
            /// Painted here rather than by each viewer, so a transparent PNG
            /// shows the editor's colour behind it instead of a flash of
            /// white.
            Color(nsColor: theme.background)

            switch document.kind {
            case .image:
                ImageViewerView(url: document.url)
            case .pdf:
                PDFViewerView(url: document.url, background: theme.background)
            }
        }
    }
}

/// What a viewer says when the bytes are not what the name promised.
///
/// A message in the pane rather than the guard's alert, because the alert
/// offers to open the file in another app and that would be bad advice: the
/// other app is going to fail on it too.
struct MediaUnreadableView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
    }
}
