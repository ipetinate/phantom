import AppKit
import SwiftUI

/// A segmented control that shows an icon beside each label.
///
/// SwiftUI's segmented `Picker` renders a `Label` as its title alone and
/// drops the image, which is why this exists at all — but a plain SwiftUI
/// track (not `NSSegmentedControl`) so the selected segment paints with the
/// terminal theme's accent like every other control here, rather than the
/// system accent color `NSSegmentedControl.selectedSegmentBezelColor`
/// (itself only honored in the `.separated` style, not `.automatic`) would
/// have been stuck on regardless of theme.
///
/// Painting with the theme's accent is also what makes the selected label a
/// judgement call rather than a constant, and what makes the keyboard work
/// this type's own responsibility: a hand-built track gets none of the
/// traversal, focus or accessibility a real segmented control ships with.
/// Both are handled below.
struct IconSegmentedControl: View {
    struct Segment {
        let value: String
        let label: String
        let image: NSImage?
    }

    let segments: [Segment]
    @Binding var selection: String

    @ObservedObject private var palette: ThemePalette = .shared

    @FocusState private var isFocused: Bool

    private var accentColor: NSColor { palette.primary ?? .controlAccentColor }

    private var accent: Color { Color(nsColor: accentColor) }

    /// The selected label's color, read off the accent it is printed on.
    ///
    /// It used to be `Color.white` unconditionally, which is right for the
    /// dark accents most themes ship and unreadable for the rest: a pastel
    /// accent, or any light theme's blue, put white text on near-white and
    /// the selected segment became the one you couldn't read.
    static func selectedForeground(on accent: NSColor) -> Color {
        accent.isLightColor ? .black : .white
    }

    /// Where an arrow key moves the selection.
    ///
    /// Stops at the ends rather than wrapping, which is what
    /// `NSSegmentedControl` does — wrapping in a control this short reads as
    /// the selection jumping rather than moving.
    static func value(from current: String, movingBy offset: Int, in values: [String]) -> String {
        guard let index = values.firstIndex(of: current) else {
            return values.first ?? current
        }
        let target = index + offset
        guard values.indices.contains(target) else { return current }
        return values[target]
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.value) { segment in
                let isSelected = segment.value == selection
                Button {
                    selection = segment.value
                } label: {
                    HStack(spacing: 4) {
                        if let image = segment.image {
                            Image(nsImage: image)
                        }
                        Text(segment.label)
                            .font(palette.font(size: 11, weight: isSelected ? .medium : .regular))
                    }
                    .foregroundStyle(
                        isSelected ? Self.selectedForeground(on: accentColor) : Color.primary
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isSelected ? accent : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(segment.label)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        )
        /// The track takes focus as one thing, so the arrow keys move along it
        /// the way they move along a real segmented control, instead of Tab
        /// walking each segment and Space clicking it.
        .focusable()
        .focused($isFocused)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isFocused ? accent : .clear, lineWidth: 2)
        )
        .onMoveCommand { direction in
            let values = segments.map(\.value)
            switch direction {
            case .left:
                selection = Self.value(from: selection, movingBy: -1, in: values)
            case .right:
                selection = Self.value(from: selection, movingBy: 1, in: values)
            default:
                break
            }
        }
        .accessibilityElement(children: .contain)
    }
}
