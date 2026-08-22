import AppKit
import Combine
import SwiftUI

/// The arrangement of a split pane: which way it is split, where the
/// divider sits, and the link between the two panes' scrolling.
///
/// One object rather than three loose pieces of `@State`, so a host can
/// persist the whole arrangement in one step and so the features that share
/// this container share one vocabulary for it.
@MainActor
final class SplitPaneModel: ObservableObject {
    /// `.horizontal` puts the panes side by side; `.vertical` stacks them.
    ///
    /// The names belong to `SplitViewDirection` and describe the direction
    /// the *panes* run in, not the divider's. Reused rather than re-spelled
    /// so the editor and the terminal splits do not end up with two words
    /// for one idea — and it is already `Codable`, which is what a host
    /// restoring a layout needs.
    @Published var direction: SplitViewDirection

    /// The smallest share either pane may be restored to.
    ///
    /// Dragging is already bounded by `SplitView`, which stops ten points
    /// short of each edge. This guards the other way in: a value read back
    /// from disk, which no drag ever checked.
    static let minimumShare: CGFloat = 0.05

    @Published private var storedSplit: CGFloat

    /// The first pane's share of the container, 0…1.
    var split: CGFloat {
        get { storedSplit }
        set { storedSplit = Self.clampedShare(newValue) }
    }

    /// Scrolling one pane moves the other — once a host turns it on.
    let scrollSync: ScrollSyncLink

    /// - Parameter scrollSync: defaulted through `nil` rather than by
    ///   writing `ScrollSyncLink()` in the signature, because a default
    ///   argument is evaluated in a **nonisolated** context even inside a
    ///   `@MainActor` type — so the obvious spelling does not compile.
    init(
        direction: SplitViewDirection = .horizontal,
        split: CGFloat = 0.5,
        scrollSync: ScrollSyncLink? = nil
    ) {
        self.direction = direction
        self.storedSplit = Self.clampedShare(split)
        self.scrollSync = scrollSync ?? ScrollSyncLink()
    }

    /// Swaps side by side for stacked and back.
    func toggleDirection() {
        direction = direction == .horizontal ? .vertical : .horizontal
    }

    static func clampedShare(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(1 - minimumShare, max(minimumShare, value))
    }
}

/// What the direction control shows and says.
///
/// Lifted out of the view because it is the one judgement in this file
/// worth pinning down in a test, and a `private var` inside a `View` cannot
/// be read from one.
enum SplitPaneDirectionToggle {
    /// The button pictures the arrangement it will *produce*, not the one
    /// already on screen.
    ///
    /// A toggle showing its current state leaves the reader deciding
    /// whether the icon is a label or a destination, and the two readings
    /// disagree about what clicking does. Showing the destination answers
    /// that before it is asked.
    static func symbol(for direction: SplitViewDirection) -> String {
        switch direction {
        case .horizontal: return "rectangle.split.1x2"
        case .vertical: return "rectangle.split.2x1"
        }
    }

    static func help(for direction: SplitViewDirection) -> String {
        switch direction {
        case .horizontal: return "Stack Panes"
        case .vertical: return "Place Panes Side by Side"
        }
    }
}

enum SplitPaneMetrics {
    /// How far the controls sit from the container's corner. Small on
    /// purpose: the control should be there when it is looked for and quiet
    /// when it is not.
    static let controlInset: CGFloat = 4

    /// The direction glyph's size. A point under the sidebar's chrome icons,
    /// because this one sits over content rather than in a chrome row and a
    /// full-weight glyph there reads as part of the document.
    static let controlGlyphSize: CGFloat = 11
}

/// The control that cuts a split the other way.
///
/// A view of its own rather than only an overlay inside the container,
/// because the corner it wants is a corner other things want too. A host
/// that already draws a cluster there can switch the container's own copy
/// off and put this in its cluster, and get one group of controls instead
/// of two overlapping ones — and a host nesting one split inside another
/// can leave a single toggle driving both.
struct SplitDirectionToggle: View {
    @ObservedObject var model: SplitPaneModel

    var body: some View {
        SidebarIconButton(help: SplitPaneDirectionToggle.help(for: model.direction)) {
            model.toggleDirection()
        } label: {
            Image(systemName: SplitPaneDirectionToggle.symbol(for: model.direction))
                .font(.system(size: SplitPaneMetrics.controlGlyphSize, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// Two panes, a divider you can drag, and a small control in the corner to
/// switch between side by side and stacked.
///
/// The layout is the window's own `SplitView` — the same one the terminal
/// splits use — so a divider dragged here behaves like every other divider
/// in the window, double-clicking it evens the panes, and the app-wide
/// "hide dividers" setting reaches this too without being taught to.
///
/// What this adds is everything `SplitView` has no opinion about: the
/// direction as state a host can persist and a reader can change, the
/// control that changes it, and a seam for keeping the two panes' scrolling
/// in step.
///
/// Panes are arbitrary views. Nothing here assumes text, an `NSTextView`,
/// or even that a pane scrolls — a pane that wants synchronised scrolling
/// puts its scroll view on `model.scrollSync` itself, either through
/// `synchronizedScroll(_:as:)` or by calling `attach(_:as:)`.
///
/// ```swift
/// @StateObject private var split = SplitPaneModel()
///
/// SplitPaneContainer(model: split) {
///     DiffPane(side: .old).synchronizedScroll(split.scrollSync, as: .first)
/// } second: {
///     DiffPane(side: .new).synchronizedScroll(split.scrollSync, as: .second)
/// }
/// ```
struct SplitPaneContainer<First: View, Second: View, Accessory: View>: View {
    @ObservedObject var model: SplitPaneModel

    /// Whether to draw the direction toggle in this container's own corner.
    ///
    /// On by default, so a container on its own is complete. Turn it off in
    /// the two cases where a second copy is worse than none: when the host
    /// already draws a cluster of controls in that corner and wants
    /// `SplitDirectionToggle` inside it instead of overlapping it, and when
    /// one container is nested in another sharing the same model, where two
    /// toggles would sit inches apart doing exactly the same thing.
    var showsDirectionToggle: Bool = true

    /// How far in from the right edge the corner controls sit, beyond the
    /// standard inset.
    ///
    /// The container cannot know what occupies its own top-right corner: in
    /// a stacked split the first pane spans it, and when that pane is a
    /// source view its minimap lives exactly there — which is how the
    /// controls came to be photographed sitting on top of one. The host
    /// knows what its panes are, so the host says how much to clear.
    var accessoryTrailingInset: CGFloat = 0

    private let first: () -> First
    private let second: () -> Second
    private let accessory: () -> Accessory

    /// - Parameter accessory: Controls to sit beside the direction toggle,
    ///   for a host that has its own thing to say in that corner — the
    ///   markdown preview's raw-or-rendered choice belongs there rather
    ///   than in a second corner of its own.
    init(
        model: SplitPaneModel,
        showsDirectionToggle: Bool = true,
        accessoryTrailingInset: CGFloat = 0,
        @ViewBuilder first: @escaping () -> First,
        @ViewBuilder second: @escaping () -> Second,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.model = model
        self.showsDirectionToggle = showsDirectionToggle
        self.accessoryTrailingInset = accessoryTrailingInset
        self.first = first
        self.second = second
        self.accessory = accessory
    }

    var body: some View {
        SplitView(
            model.direction,
            $model.split,
            dividerColor: Self.dividerColor,
            left: first,
            right: second,
            onEqualize: { model.split = 0.5 }
        )
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                accessory()
                if showsDirectionToggle {
                    SplitDirectionToggle(model: model)
                }
            }
            .padding(SplitPaneMetrics.controlInset)
            .padding(.trailing, accessoryTrailingInset)
        }
    }

    /// The window's divider setting, minus the terminal's own colour: an
    /// editor split has no surface configuration to ask, and the separator
    /// is what the rest of the window's non-terminal dividers fall back to.
    private static var dividerColor: Color {
        switch AppearanceCoordinator.dividerMode {
        case .hidden: return .clear
        case .custom(let color): return Color(nsColor: color)
        case .system: return Color(nsColor: .separatorColor)
        }
    }
}

extension SplitPaneContainer where Accessory == EmptyView {
    init(
        model: SplitPaneModel,
        showsDirectionToggle: Bool = true,
        accessoryTrailingInset: CGFloat = 0,
        @ViewBuilder first: @escaping () -> First,
        @ViewBuilder second: @escaping () -> Second
    ) {
        self.init(
            model: model,
            showsDirectionToggle: showsDirectionToggle,
            accessoryTrailingInset: accessoryTrailingInset,
            first: first,
            second: second,
            accessory: { EmptyView() }
        )
    }
}
