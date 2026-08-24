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

    @ObservedObject private var palette: ThemePalette = .shared

    /// How tall a tab is, and how much room is left under it for the
    /// scroller. Named because three places have to agree on them: the row,
    /// the scroll view around it, and the inset the terminal below is pushed
    /// down by.
    static let tabHeight: CGFloat = 30
    static let scrollerStrip: CGFloat = 8

    static var height: CGFloat { tabHeight + scrollerStrip }

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
                        onSelect: onSelectTerminal
                    )
                }

                ForEach(tabs) { tab in
                    EditorTabItem(
                        tab: tab,
                        isSelected: selection == .file(tab.id),
                        showsDirectory: needsDirectory(tab),
                        isDivergent: isDivergent(tab),
                        hasSiblings: tabs.count > 1,
                        onSelect: { onSelect(tab.id) },
                        onClose: { onClose(tab.id) },
                        onCommand: { onCommand($0, tab) }
                    )
                }

                // Overlay, not legacy. With "show scroll bars: always" in
                // System Settings a legacy scroller is permanent and claims a
                // strip of layout for itself, and there was no such strip —
                // so it was drawn clipped, over the bottom edge of the bar and
                // the rule under it. Overlay draws thin, over the content, and
                // fades when the scrolling stops.
                OverlayScrollers()

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
        .frame(height: Self.tabHeight + Self.scrollerStrip)
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
    let onSelect: () -> Void

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
                onClick: { _ in onSelect() },
                /// The terminal's tab has no menu: it cannot be closed, it has
                /// no path to reveal or copy, and every command there is would
                /// be greyed out.
                onMenu: {}
            )
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help(title)
    }

    /// The terminal's tab, for the drag. Its own glyph and title, in the
    /// shape `EditorTabItem.dragPreview` uses, so the two tabs travel alike.
    private var dragPreview: NSImage? {
        let renderer = ImageRenderer(
            content: HStack(spacing: 5) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 11))

                Text(title)
                    .font(palette.font(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: EditorTabBar.tabHeight)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(accent.opacity(0.7), lineWidth: 1)
            )
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

    /// Whether this bar holds more than this tab, which is what decides
    /// whether "Close Others" is offered.
    let hasSiblings: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCommand: (EditorTabCommand) -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var icons: FileIconProvider = .shared
    @State private var isHovered = false

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        HStack(spacing: 5) {
            /// Everything but the close control, grouped so the gesture layer
            /// can sit over it and leave that control alone. The layer is an
            /// AppKit view and takes every click under it, so laid over the
            /// whole tab it would swallow the one button in here.
            HStack(spacing: 5) {
                FileIconView(icon: icons.icon(forFile: tab.name), size: 13)

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
                    onMenu: showMenu
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
        for entry in EditorTabCommand.menu(hasSiblings: hasSiblings) {
            switch entry {
            case .separator:
                popup.addItem(.separator())
            case .command(let command):
                popup.addItem(ClosureMenuItem(title: command.title) { onCommand(command) })
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
    /// Rounded and outlined, unlike the tab in the bar. On screen a tab is
    /// square-cornered because it sits in a row of them; lifted out and
    /// following the pointer it is a single object, and a floating square with
    /// no edge reads as a piece of the window that came loose.
    private var dragPreview: NSImage? {
        let renderer = ImageRenderer(
            content: HStack(spacing: 5) {
                FileIconView(icon: icons.icon(forFile: tab.name), size: 13)

                Text(tab.name)
                    .font(palette.font(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: EditorTabBar.tabHeight)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(accent.opacity(0.7), lineWidth: 1)
            )
            .frame(maxWidth: 280)
        )

        /// Rendered for this screen, or the drag carries a blurred copy of
        /// the tab on a Retina display.
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
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
