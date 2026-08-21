import SwiftUI

/// The backing behind a small control that floats over a document.
///
/// Always drawn, which is the whole difference between a control you can find
/// and one you have to know about. It used to appear only on hover, so at rest
/// the glyphs floated unbacked over whatever the editor happened to be drawing
/// — and the place they sit is beside the minimap, the busiest, most
/// multicoloured strip in the window. Contrast cannot come from the glyph alone
/// when the thing behind it is arbitrary.
///
/// `.regularMaterial` rather than `.thinMaterial`: thin lets the code
/// underneath read straight through, which is the property that made this hard
/// to see. The extra wash on hover is the affordance now, rather than the
/// background's whole existence.
///
/// Shared rather than copied because there are two of these now — the
/// presentation control and the media pane's own chrome — and a second opinion
/// about the material would be a second thing to keep in step.
struct EditorOverlayBackground: View {
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.22 : 0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
    }
}

extension View {
    func editorOverlayChrome(isHovered: Bool) -> some View {
        background(EditorOverlayBackground(isHovered: isHovered))
    }
}
