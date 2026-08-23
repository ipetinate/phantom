import SwiftUI

/// A split view shows a left and right (or top and bottom) view with a divider in the middle to do resizing.
/// The terminlogy "left" and "right" is always used but for vertical splits "left" is "top" and "right" is "bottom".
///
/// This view is purpose built for our use case and I imagine we'll continue to make it more configurable
/// as time goes on. For example, the splitter divider size and styling is all hardcoded.
struct SplitView<L: View, R: View>: View {
    /// Direction of the split
    let direction: SplitViewDirection

    /// What the Default divider mode falls back to when the theme offers no
    /// swatch of its own — the caller's historical divider colour. The full
    /// mode resolution lives in `dividerColor` below, so every split in the
    /// window answers the one setting the same way; callers only supply
    /// this fallback.
    let systemDividerColor: Color

    /// Minimum increment (in points) that this split can be resized by, in
    /// each direction. Both `height` and `width` should be whole numbers
    /// greater than or equal to 1.0
    let resizeIncrements: NSSize

    /// The left and right views to render.
    let left: L
    let right: R

    /// Called when the divider is double-tapped to equalize splits.
    let onEqualize: () -> Void

    /// The minimum size (in points) of a split
    let minSize: CGFloat = 10

    /// The current fractional width of the split view. 0.5 means L/R are equally sized, for example.
    @Binding var split: CGFloat

    /// The visible size of the splitter, in points. The invisible size is a transparent hitbox that can still
    /// be used for getting a resize handle. The total width/height of the splitter is the sum of both.
    ///
    /// A hidden divider takes no space rather than being drawn clear: the
    /// strip would still be there, showing the window through it, which over
    /// a transparent background reads as a line of its own.
    ///
    /// Internal rather than private so a regression test can check this
    /// directly instead of only through rendered geometry.
    var splitterVisibleSize: CGFloat {
        AppearanceCoordinator.dividerMode.isHidden ? 0 : 1
    }

    /// The colour the divider paints, resolved from the window-wide setting:
    /// the divider setting covers every divider in the window — a user who
    /// turned dividers off doesn't want one reappearing between panes. The
    /// Default mode takes the theme's own swatch when there is one.
    ///
    /// Reads `dividerStyleGeneration` first, and that read is load-bearing:
    /// it runs during body evaluation, which makes the generation a
    /// dependency of this view — the bump in `onReceive` then invalidates
    /// exactly this split when the divider settings change.
    var dividerColor: Color {
        _ = dividerStyleGeneration
        switch AppearanceCoordinator.dividerMode {
        case .hidden: return .clear
        case .custom(let color): return Color(nsColor: color)
        case .system:
            guard let themed = AppearanceCoordinator.themeDividerColor else {
                return systemDividerColor
            }
            return Color(nsColor: themed)
        }
    }

    /// Bumped when the divider settings change, so the mode and colour
    /// picked in Settings land on every open split immediately — without
    /// this, a split re-read the setting only on its next unrelated
    /// re-render, which is the "transparent strip until relaunch" bug's
    /// SwiftUI sibling.
    @State private var dividerStyleGeneration = 0

    private let splitterInvisibleSize: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let leftRect = self.leftRect(for: geo.size)
            let rightRect = self.rightRect(for: geo.size, leftRect: leftRect)
            let splitterPoint = self.splitterPoint(for: geo.size, leftRect: leftRect)

            ZStack(alignment: .topLeading) {
                left
                    .frame(width: leftRect.size.width, height: leftRect.size.height)
                    .offset(x: leftRect.origin.x, y: leftRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(leftPaneLabel)
                right
                    .frame(width: rightRect.size.width, height: rightRect.size.height)
                    .offset(x: rightRect.origin.x, y: rightRect.origin.y)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(rightPaneLabel)
                Divider(direction: direction,
                        visibleSize: splitterVisibleSize,
                        invisibleSize: splitterInvisibleSize,
                        color: dividerColor,
                        split: $split)
                    .position(splitterPoint)
                    .gesture(dragGesture(geo.size, splitterPoint: splitterPoint))
                    .onTapGesture(count: 2) {
                        onEqualize()
                    }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(splitViewLabel)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: TerminalController.sidebarTintDidChange)
        ) { _ in
            dividerStyleGeneration &+= 1
        }
    }

    /// Initialize a split view that can be resized by manually dragging the divider.
    init(
        _ direction: SplitViewDirection,
        _ split: Binding<CGFloat>,
        systemDividerColor: Color,
        resizeIncrements: NSSize = .init(width: 1, height: 1),
        @ViewBuilder left: (() -> L),
        @ViewBuilder right: (() -> R),
        onEqualize: @escaping () -> Void
    ) {
        self.direction = direction
        self._split = split
        self.systemDividerColor = systemDividerColor
        self.resizeIncrements = resizeIncrements
        self.left = left()
        self.right = right()
        self.onEqualize = onEqualize
    }

    private func dragGesture(_ size: CGSize, splitterPoint: CGPoint) -> some Gesture {
        return DragGesture()
            .onChanged { gesture in
                switch direction {
                case .horizontal:
                    let new = min(max(minSize, gesture.location.x), size.width - minSize)
                    split = new / size.width

                case .vertical:
                    let new = min(max(minSize, gesture.location.y), size.height - minSize)
                    split = new / size.height
                }
            }
    }

    /// Calculates the bounding rect for the left view.
    private func leftRect(for size: CGSize) -> CGRect {
        // Initially the rect is the full size
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        switch direction {
        case .horizontal:
            result.size.width *= split
            result.size.width -= splitterVisibleSize / 2
            result.size.width -= result.size.width.truncatingRemainder(dividingBy: self.resizeIncrements.width)

        case .vertical:
            result.size.height *= split
            result.size.height -= splitterVisibleSize / 2
            result.size.height -= result.size.height.truncatingRemainder(dividingBy: self.resizeIncrements.height)
        }

        return result
    }

    /// Calculates the bounding rect for the right view.
    private func rightRect(for size: CGSize, leftRect: CGRect) -> CGRect {
        // Initially the rect is the full size
        var result = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        switch direction {
        case .horizontal:
            // For horizontal layouts we offset the starting X by the left rect
            // and make the width fit the remaining space.
            result.origin.x += leftRect.size.width
            result.origin.x += splitterVisibleSize / 2
            result.size.width -= result.origin.x

        case .vertical:
            result.origin.y += leftRect.size.height
            result.origin.y += splitterVisibleSize / 2
            result.size.height -= result.origin.y
        }

        return result
    }

    /// Calculates the point at which the splitter should be rendered.
    private func splitterPoint(for size: CGSize, leftRect: CGRect) -> CGPoint {
        switch direction {
        case .horizontal:
            return CGPoint(x: leftRect.size.width, y: size.height / 2)

        case .vertical:
            return CGPoint(x: size.width / 2, y: leftRect.size.height)
        }
    }

    // MARK: Accessibility

    private var splitViewLabel: String {
        switch direction {
        case .horizontal:
            return "Horizontal split view"
        case .vertical:
            return "Vertical split view"
        }
    }

    private var leftPaneLabel: String {
        switch direction {
        case .horizontal:
            return "Left pane"
        case .vertical:
            return "Top pane"
        }
    }

    private var rightPaneLabel: String {
        switch direction {
        case .horizontal:
            return "Right pane"
        case .vertical:
            return "Bottom pane"
        }
    }
}

enum SplitViewDirection: Codable {
    case horizontal, vertical
}
