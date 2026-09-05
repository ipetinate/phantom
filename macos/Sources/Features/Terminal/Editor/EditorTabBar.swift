import AppKit
import SwiftUI

/// The row of open files above the editor.
///
/// Reuses `FileIconView` and the icon theme the explorer, the Git panel and
/// the terminal tabs already use, so a file looks the same everywhere it
/// appears.
struct EditorTabBar: View {
    let tabs: [EditorTab]
    let selection: EditorSelection
    let needsDirectory: (EditorTab) -> Bool

    /// Whether this tab's file is from a worktree its terminal has left.
    /// Asked rather than derived here: the answer needs the terminal's
    /// working directory and the filesystem, and this row knows neither.
    let isDivergent: (EditorTab) -> Bool
    let onSelect: (String) -> Void
    let onClose: (String) -> Void

    /// What the tab's own menu asks for. One closure rather than one per
    /// command: the menu is described by `EditorTabCommand`, and a callback
    /// per item would mean this row growing a parameter every time that
    /// description does.
    let onCommand: (EditorTabCommand, EditorTab) -> Void

    /// What each tab can be asked to do. Asked per tab rather than per bar:
    /// only the centre knows whether a tab's cell survives it leaving, and
    /// whether the main pane is somewhere else.
    let availability: (EditorTab) -> EditorTabCommand.Availability

    /// The same, for the terminal's own tab, and what its menu asks for.
    let terminalAvailability: EditorTabCommand.Availability
    let onTerminalCommand: (EditorTabCommand) -> Void

    /// The title of the terminal this pane belongs to, for its own tab.
    let terminalTitle: String
    let onSelectTerminal: () -> Void

    /// Whether the terminal lives in *this* cell.
    ///
    /// With a grid there are several bars and one terminal, so the tab for it
    /// is drawn by the cell that holds it and by no other — a second copy
    /// would be a control that moves the shell out from under the reader who
    /// clicked it.
    let hostsTerminal: Bool

    /// The reviews open in this cell, in tab order. Values rather than the
    /// centre — the same rule the terminal's title follows.
    var reviews: [GitReviewScope] = []
    var onSelectReview: (GitReviewScope) -> Void = { _ in }
    var onCloseReview: (GitReviewScope) -> Void = { _ in }

    /// Moves a tab along the bar, and answers how many places it moved.
    ///
    /// The gesture that asks is `EditorTabGesture`, which reorders on a
    /// sideways drag and hands the tab to the split drag only when it is
    /// pulled out of the row. It is told how far the tab really went because
    /// the strip refuses a move across the pinned boundary, and a gesture
    /// counting a refused move would drift out of step with what it sees.
    var onReorder: (EditorTab, Int) -> Int = { _, _ in 0 }

    @ObservedObject private var palette: ThemePalette = .shared

    /// How tall a tab is. Named because three places have to agree on it:
    /// the row, the scroll view around it, and the inset the terminal below
    /// is pushed down by.
    ///
    /// There used to be a `scrollerStrip` of 8 points under the row, reserved
    /// so an overlay scroller had somewhere to be drawn that was not across
    /// the tab labels. `InvisibleScrollers` removed the knob, so the band it
    /// was keeping clear has nothing left to keep clear.
    static let tabHeight: CGFloat = 30

    static var height: CGFloat { tabHeight }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                // First in its own cell, and not closable: the pane belongs
                // to the terminal, and the files are guests in it. A close
                // button here would offer to remove the thing that owns the
                // window.
                if hostsTerminal {
                    TerminalTabItem(
                        title: terminalTitle,
                        isSelected: selection == .terminal,
                        availability: terminalAvailability,
                        onSelect: onSelectTerminal,
                        onCommand: onTerminalCommand
                    )
                }

                /// After the terminal and before the files, which is where it
                /// was opened from: the reader asked for it while looking at
                /// the branch, not while looking at a file. Closable, unlike
                /// the terminal — it is a guest here too.
                /// One tab per review, because two commits are two screens:
                /// a reader comparing them switches between the tabs, and a
                /// strip with one row could only ever show the last commit
                /// clicked.
                ForEach(reviews) { scope in
                    EditorReviewTabItem(
                        title: scope.tabTitle,
                        help: scope.tabHelp,
                        isSelected: selection == .review(scope.id),
                        onSelect: { onSelectReview(scope) },
                        onClose: { onCloseReview(scope) }
                    )
                }

                ForEach(tabs) { tab in
                    EditorTabItem(
                        tab: tab,
                        isSelected: selection == .file(tab.id),
                        showsDirectory: needsDirectory(tab),
                        isDivergent: isDivergent(tab),
                        availability: availability(tab),
                        onSelect: { onSelect(tab.id) },
                        onClose: { onClose(tab.id) },
                        onCommand: { onCommand($0, tab) },
                        onReorder: { onReorder(tab, $0) }
                    )
                }

                // Overlay, not legacy. With "show scroll bars: always" in
                // System Settings a legacy scroller is permanent and claims a
                // strip of layout for itself, and there was no such strip —
                // so it was drawn clipped, over the bottom edge of the bar and
                // the rule under it. Overlay draws thin, over the content, and
                // fades when the scrolling stops.
                InvisibleScrollers()

                // Wheel down scrolls the row sideways, because reaching for a
                // tab off the right edge with a mouse otherwise means a
                // horizontal gesture nobody has on a wheel.
                WheelScrollsHorizontally()
            }
            .frame(height: Self.tabHeight)
            // No `Spacer` here on purpose: a spacer stretches the row to the
            // viewport's width, so the content never overflows and a scroll
            // view with nothing to overflow does not scroll. The row is as
            // wide as its tabs; the background behind it fills the rest.
        }
        // Visible while scrolling, not never: with enough tabs to fill the
        // bar there was no way to reach the rest and nothing to say they were
        // there. `.never` hid the only affordance the row had.
        .scrollIndicators(.automatic)
        // Taller than the tabs by exactly the strip the overlay scroller
        // needs. Two things come out of that gap: the scroller stops being
        // drawn over the tab labels and over the rule at the bottom of the
        // bar, and the row stops being *vertically* scrollable — content
        // taller than its viewport is what made a wheel event scroll a few
        // invisible points up and down instead of moving the tabs.
        .frame(height: Self.tabHeight)
    }
}

/// The terminal's own tab.
///
/// Deliberately not an `EditorTabItem` with a fake path: it has no dirty
/// dot, no close button and no directory to disambiguate, and modelling it
/// as a file would mean every rule in there growing a special case.
private struct TerminalTabItem: View {
    let title: String
    let isSelected: Bool
    let availability: EditorTabCommand.Availability
    let onSelect: () -> Void
    let onCommand: (EditorTabCommand) -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @State private var isHovered = false

    private var accent: Color { palette.accent ?? .accentColor }

    /// Neither a `Button` nor a tap gesture: the gestures belong to
    /// `EditorTabDragSource`, laid over the tab.
    ///
    /// A button's own gesture used to win over `.onDrag`, so as a button this
    /// tab could be clicked and never dragged — the terminal was the one tab
    /// in the bar that could not be moved, which is the whole reason it has a
    /// tab. The AppKit layer settles that and the operation mask both.
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 11))

            Text(title)
                .font(palette.font(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
        }
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isSelected ? accent.opacity(0.18) : (isHovered ? Color.secondary.opacity(0.10) : .clear))
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle().fill(accent).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .overlay {
            EditorTabDragSource(
                item: .terminal,
                label: title,
                preview: { dragPreview },
                onClick: { clicks in
                    if clicks >= 2 { showMenu() } else { onSelect() }
                },
                onMenu: showMenu
            )
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help(title)
    }

    /// The terminal's own menu: the four splits and nothing else.
    ///
    /// It cannot be closed — the pane belongs to it — and it has no path to
    /// reveal or to copy. `EditorTabCommand.menu` leaves all of that out on
    /// its own: the availability it is given says the terminal is already in
    /// the main pane, and the close commands are filtered here because they
    /// are the one group this tab must never offer.
    private func showMenu() {
        let popup = NSMenu()
        for entry in EditorTabCommand.menu(availability) {
            switch entry {
            case .separator:
                popup.addItem(.separator())
            case .command(let command):
                guard command.zone != nil else { continue }
                popup.addItem(
                    ClosureMenuItem(title: command.title, systemImage: command.icon) {
                        onCommand(command)
                    })
            }
        }

        guard !popup.items.isEmpty else { return }
        popup.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The terminal's tab, for the drag: its own glyph and title, in the shape
    /// `EditorTabItem.dragPreview` uses, so the two tabs travel alike. No
    /// close mark, because this tab has none.
    private var dragPreview: NSImage? {
        let renderer = ImageRenderer(
            content: HStack(spacing: 5) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 11))

                Text(title)
                    .font(palette.font(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: EditorTabBar.tabHeight)
            .background {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    accent.opacity(0.18)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(accent).frame(height: 2)
            }
            .frame(maxWidth: 280)
        )

        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}

private struct EditorTabItem: View {
    let tab: EditorTab
    let isSelected: Bool
    let showsDirectory: Bool
    let isDivergent: Bool

    /// What this tab can be asked to do, which depends on where it is in the
    /// grid. Resolved by the centre, which is what knows.
    let availability: EditorTabCommand.Availability
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCommand: (EditorTabCommand) -> Void

    /// See ``EditorTabBar/onReorder``.
    let onReorder: (Int) -> Int

    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var icons: FileIconProvider = .shared
    @State private var isHovered = false

    private var accent: Color { palette.accent ?? .accentColor }

    private var tabIcon: FileIcon {
        tab.symbol.map { .symbol(name: $0, color: .secondary) } ?? icons.icon(forFile: tab.name)
    }

    var body: some View {
        HStack(spacing: 5) {
            /// Everything but the close control, grouped so the gesture layer
            /// can sit over it and leave that control alone. The layer is an
            /// AppKit view and takes every click under it, so laid over the
            /// whole tab it would swallow the one button in here.
            HStack(spacing: 5) {
                FileIconView(icon: tabIcon, size: 13)

                pinMark

                Text(tab.name)
                    .font(palette.font(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)

                if showsDirectory {
                    Text((tab.directory as NSString).lastPathComponent)
                        .font(palette.font(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                divergenceMark
            }
            .contentShape(Rectangle())
            .overlay {
                EditorTabDragSource(
                    item: .file(tab.path),
                    label: tab.name,
                    preview: { dragPreview },
                    onClick: { clicks in
                        if clicks >= 2 { showMenu() } else { onSelect() }
                    },
                    onMenu: showMenu,
                    onReorder: onReorder
                )
            }

            closeControl
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isSelected ? accent.opacity(0.18) : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(accent)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        // The I-beam has to be pushed back explicitly: it belongs to the
        // text view underneath, and AppKit keeps it while the pointer is
        // over a SwiftUI view that never says otherwise — so a tab looked
        // like something to select text in rather than something to click.
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help(tab.path)
    }

    /// The menu, popped at the pointer.
    ///
    /// One renderer for both openings, unlike the explorer's rows: the
    /// gestures here are AppKit's, so the right click arrives as
    /// `rightMouseDown` and the double click as a `clickCount` of two, and
    /// neither of them is a SwiftUI `.contextMenu`.
    private func showMenu() {
        let popup = NSMenu()
        for entry in EditorTabCommand.menu(availability) {
            switch entry {
            case .separator:
                popup.addItem(.separator())
            case .command(let command):
                popup.addItem(
                    ClosureMenuItem(title: command.title, systemImage: command.icon) {
                        onCommand(command)
                    })
            }
        }
        popup.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The tab itself, for the thing that follows the pointer while it is
    /// dragged.
    ///
    /// Rendered by SwiftUI, because SwiftUI is what draws the tab: an AppKit
    /// snapshot of a SwiftUI view comes back empty, and a shape drawn by hand
    /// in AppKit is a second opinion about how a tab looks that would drift
    /// from this one. The same icon, the same name, the same font.
    ///
    /// The selected tab, square-cornered, close mark and accent rule and all.
    /// A rounded pill with a border was the first version and it looked like
    /// a control from another app; what should follow the pointer is the tab.
    ///
    /// Opaque underneath, which is the one departure and not a choice: in the
    /// bar the tab's tint sits over the pane's own coat, and rendered on its
    /// own that tint is half transparent and lets the desktop through.
    private var dragPreview: NSImage? {
        let renderer = ImageRenderer(
            content: HStack(spacing: 5) {
                FileIconView(icon: tabIcon, size: 13)

                /// The same mark the tab wears in the bar. What follows the
                /// pointer has to *be* the tab, and a pinned tab that shed
                /// its pin on the way to another cell would be saying the
                /// pin does not travel — which is exactly what it does.
                pinMark

                Text(tab.name)
                    .font(palette.font(size: 11, weight: .semibold))
                    .lineLimit(1)

                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .padding(.horizontal, 10)
            .frame(height: EditorTabBar.tabHeight)
            .background {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    accent.opacity(0.18)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(accent).frame(height: 2)
            }
            .frame(maxWidth: 280)
        )

        /// Rendered for this screen, or the drag carries a blurred copy of
        /// the tab on a Retina display.
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    /// The pin mark, *beside* the file's own icon and never in place of it.
    ///
    /// The file icon is how a tab is found at a glance — the explorer, the
    /// Git panel and this bar all draw the same one, which is the point of
    /// sharing `FileIconView` — so a pin that took its slot would trade the
    /// tab's identity for a fact the tab's position in the bar already
    /// states. It goes at the leading edge, next to the icon, because that is
    /// the end of the tab the eye is already at when it reads the run of
    /// pinned tabs from the left.
    @ViewBuilder
    private var pinMark: some View {
        if tab.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }

    /// The worktree mark, for a tab whose file is from a checkout its
    /// terminal has left.
    ///
    /// The sidebar's own glyph rather than a new one, so "this is about
    /// worktrees" is the same shape wherever it is said. Tinted, and that is
    /// the whole difference from the sidebar's use of it: there the mark is
    /// information, here it is a discrepancy, and the banner over the
    /// document is where it gets explained.
    ///
    /// Its own slot rather than the dirty dot's. The two are independent —
    /// a document stays behind on a worktree switch *because* it is dirty,
    /// so the common case is both at once — and folding them together would
    /// make the more urgent of the two hide the other.
    @ViewBuilder
    private var divergenceMark: some View {
        if isDivergent {
            WorktreeIcon(size: 9)
                .foregroundStyle(.orange)
        }
    }

    /// A dot for unsaved changes that becomes the close button on hover —
    /// the VS Code behavior, which keeps one slot doing both jobs instead
    /// of widening every tab to fit two.
    ///
    /// A pinned tab keeps it. Hiding the button there is what some editors
    /// do, and here it would take the dirty dot down with it — one slot,
    /// two jobs — leaving a pinned tab with unsaved edits nothing to click
    /// and making every tab change width the moment it is pinned. See
    /// `EditorTab.isPinned` for the whole of that decision.
    @ViewBuilder
    private var closeControl: some View {
        if tab.isDirty && !isHovered {
            Circle()
                .fill(.secondary)
                .frame(width: 7, height: 7)
                .frame(width: 14, height: 14)
        } else {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                    )
            }
            .buttonStyle(.plain)
            .opacity(isHovered || tab.isDirty ? 1 : 0.35)
        }
    }
}

// MARK: - The scrollbar that used to run through the tabs

/// A scroller that occupies its place and draws nothing.
///
/// The tab strip drew a horizontal bar through the middle of the row, and a
/// tab strip is the one place a scroller has nothing to add: a strip with more
/// tabs than fit already says so by clipping one at its edge, which is the
/// affordance every editor with a scrolling tab strip relies on.
///
/// **A scroller that draws nothing, rather than `hasHorizontalScroller = false`.**
/// Turning the scroller off does not only remove the indicator: an
/// `NSScrollView` resolves `horizontalScrollElasticity` of `.automatic`
/// against whether that axis has a scroller, so switching it off puts the
/// strip's own scrolling at risk — and the strip has to keep scrolling by
/// trackpad and by shift-wheel, which is how a tab past the right edge is
/// reached at all.
///
/// **And why `OverlayScrollers()` is replaced here rather than deleted.** That
/// call is what keeps a *legacy* scroller off the row: with "Show scroll bars:
/// Always" in System Settings, AppKit gives every scroll view a legacy
/// scroller, which is permanent and claims a column of layout for itself.
/// Deleting the call brings that back — a wider bar than the one being
/// removed, drawn clipped over the tab labels.
///
/// `.scrollIndicators(.hidden)` is not the answer either, for the reason
/// `OverlayScrollers` already records: the modifier does not reach the
/// scroller SwiftUI's own scroll view draws.
final class InvisibleScroller: NSScroller {
    override static func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        0
    }

    /// Required of any `NSScroller` subclass used as an overlay scroller,
    /// which is the style this installs.
    override static var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {}

    override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {}
}

/// Puts an ``InvisibleScroller`` on the enclosing scroll view, in place of the
/// thin one `OverlayScrollers` installs.
///
/// Placed inside the scroll view's content with no size of its own, so it can
/// find its way up to the scroll view and otherwise does nothing — the same
/// shape, and for the same reason, as `OverlayScrollers`.
private struct InvisibleScrollers: View {
    var body: some View {
        Representable()
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private struct Representable: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { Finder() }

        func updateNSView(_ nsView: NSView, context: Context) {
            (nsView as? Finder)?.apply()
        }
    }

    private final class Finder: NSView {
        /// Applied on arrival in a window, which is the first moment there is
        /// a scroll view above this to find.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        /// Idempotent, because SwiftUI calls `updateNSView` on every pass and
        /// replacing a scroller mid-fade throws away the one being drawn.
        func apply() {
            guard let scrollView = enclosingScrollView else { return }
            guard !(scrollView.horizontalScroller is InvisibleScroller) else { return }

            /// Overlay as well as invisible. The style is what stops AppKit
            /// from parking a scroller in the layout forever for a reader
            /// whose System Settings say to always show scroll bars.
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.horizontalScroller = InvisibleScroller()
            scrollView.verticalScroller = InvisibleScroller()
        }
    }
}
