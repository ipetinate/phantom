import AppKit
import Combine
import Foundation

/// App-wide sidebar collapse state. Shared by every window so switching
/// tabs never changes the sidebar geometry, and persisted so it
/// survives relaunches.
@MainActor
final class SidebarCollapseState: ObservableObject {
    static let shared = SidebarCollapseState()

    @Published var isCollapsed: Bool {
        didSet {
            UserDefaults.standard.set(isCollapsed, forKey: "SidebarCollapsed")
        }
    }

    init() {
        isCollapsed = UserDefaults.standard.bool(forKey: "SidebarCollapsed")
    }
}

/// Window-level sidebar actions and state shared between the controller
/// (which owns the split view) and the SwiftUI sidebar chrome.
@MainActor
final class SidebarLayoutModel: ObservableObject {
    /// Creates a new terminal tab in this window's tab group.
    var onNewTab: () -> Void = {}

    /// Creates a new terminal tab that immediately starts a Claude session.
    var onNewClaudeTab: () -> Void = {}

    /// Creates a new terminal tab that immediately starts a Codex session.
    var onNewCodexTab: () -> Void = {}

    /// Creates a new terminal tab that immediately starts an OpenCode session.
    var onNewOpenCodeTab: () -> Void = {}

    /// Creates a new terminal tab that immediately starts an Antigravity
    /// session.
    var onNewAntigravityTab: () -> Void = {}

    /// Opens a terminal — or a terminal already running an agent — with its
    /// cwd inside a chosen worktree. Wired by the controller like the
    /// callbacks above; the worktree pane is the only caller.
    var onNewWorktreeTab: (String) -> Void = { _ in }
    var onNewWorktreeAgentTab: (String, CodingAgent) -> Void = { _, _ in }

    /// The same, from inside a group's header — where the terminal has to
    /// land *in that group*. Pressing a button on a group and watching the
    /// terminal appear at the bottom of the list, outside it, is the
    /// gesture doing half of what it said.
    var onNewWorktreeTabInGroup: (SidebarGroup, String) -> Void = { _, _ in }

    /// Which panel the sidebar is showing.
    ///
    /// Per-window, and deliberately **not** persisted. Every terminal tab is
    /// its own window with its own sidebar, so a remembered "last used
    /// panel" meant that switching tabs landed you in the file explorer you
    /// had opened somewhere else entirely — the panel appeared to follow you
    /// around. Files is somewhere you go on purpose, so a window always
    /// starts on terminals and only an actual click on the tab moves it.
    ///
    /// This lives here because both `SidebarView` and `SidebarTitlebarChrome`
    /// already observe this object, so the panel switch reaches the sidebar
    /// body and the titlebar buttons with no extra wiring.
    @Published var selectedPane: SidebarPane = .terminals

    /// How much of the window's titlebar strip the sidebar keeps clear on
    /// its own, applied as top padding by `SidebarView`.
    ///
    /// Zero for an ordinary window, where AppKit already reserves the strip
    /// for us. In native fullscreen it is the strip's full height, because
    /// there AppKit reserves none of it — see `titlebarShortfall`.
    ///
    /// Per window rather than app-wide: one window can be fullscreen while
    /// its siblings are not, and each sidebar has to answer for its own.
    @Published var titlebarInset: CGFloat = 0

    /// The part of the titlebar strip the window is not reserving.
    ///
    /// The one number behind the whole fullscreen strip: the sidebar takes it
    /// as padding, and the terminal pane's filler and tab bar take it as the
    /// offset from the terminal's safe area (`syncTitlebarStripInsets`).
    ///
    /// While a window is ordinary, its titlebar belongs to it: the content
    /// stops below the strip, and the sidebar's first row lands under the
    /// traffic lights without anyone arranging it. Native fullscreen moves
    /// the titlebar into a separate `NSToolbarFullScreenWindow` and hands
    /// the whole frame back as content, so nothing is reserved any more —
    /// while the traffic lights and the sidebar's own titlebar icons keep
    /// drawing over that strip. That is how the pane switcher ended up
    /// underneath the close button in fullscreen, and how the strip over the
    /// terminal went back to showing the bare window.
    ///
    /// A difference rather than a flat strip height, so it cannot double up
    /// and needs no mode to switch on. Whatever the window still reserves is
    /// subtracted, and outside fullscreen that is always the larger of the two
    /// — `NSTitlebarView` is measured inside the titlebar container, which is
    /// what the window stops its content below — so this is zero there
    /// structurally, and a macOS that starts reserving the strip in fullscreen
    /// again returns to zero on its own instead of insetting anything twice.
    static func titlebarShortfall(
        titlebarHeight: CGFloat,
        reservedByWindow: CGFloat
    ) -> CGFloat {
        max(0, titlebarHeight - max(0, reservedByWindow))
    }
}

/// The sidebar | terminal split view, with a user-configurable divider:
/// default system color, hidden, or a custom color.
final class SidebarSplitView: NSSplitView {
    /// The pane whose tabs the ⌥⌘ shortcuts move between.
    ///
    /// Handled here, and not in `CodeNSTextView`, because that view is only
    /// in the responder chain while the *editor* has focus — and the whole
    /// point of the shortcut is to reach a file while you are typing in the
    /// terminal. This split view is the window's content view, so its
    /// `performKeyEquivalent` is consulted before the terminal surface sees
    /// the key.
    weak var editorCenter: EditorCenter?

    /// The standard editing keys, when a field in the sidebar has focus.
    ///
    /// Ghostty binds ⌘V, ⌘C, ⌘X and friends to the *terminal* above the
    /// responder chain, so a text field in the sidebar never saw them: typing
    /// in the search box worked and pasting into it did nothing. Handled here
    /// because this view is consulted before the surface, and only when the
    /// thing with focus is an editable field — otherwise the terminal keeps
    /// every one of them.
    private static let editingCommands: [String: Selector] = [
        "v": #selector(NSText.paste(_:)),
        "c": #selector(NSText.copy(_:)),
        "x": #selector(NSText.cut(_:)),
        "a": #selector(NSText.selectAll(_:)),
    ]

    private func routeEditingCommand(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command,
              let characters = event.charactersIgnoringModifiers?.lowercased(),
              let selector = Self.editingCommands[characters],
              let responder = window?.firstResponder
        else { return false }

        // Editable text only. A terminal surface is a responder too, and it
        // must keep these keys.
        guard let textView = responder as? NSTextView, textView.isEditable,
              textView.isDescendant(of: self)
        else { return false }

        return NSApp.sendAction(selector, to: responder, from: nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if routeEditingCommand(event) { return true }

        if let center = editorCenter,
           let zone = EditorCommands.divideZone(
               keyCode: event.keyCode, modifiers: event.modifierFlags) {
            center.divideFocusedCell(zone)
            return true
        }

        if let center = editorCenter,
           let characters = event.charactersIgnoringModifiers,
           let command = EditorCommands.paneCommand(
               for: characters,
               modifiers: event.modifierFlags,
               hasOpenFiles: !center.tabs.isEmpty
           ) {
            switch command {
            case .toggleTerminal: center.toggleTerminal()
            case .selectFile(let number): center.selectFile(at: number)
            }
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override var dividerColor: NSColor {
        switch AppearanceCoordinator.dividerMode {
        case .hidden: return .clear
        case .custom(let color): return color
        case .system:
            return AppearanceCoordinator.themeDividerColor ?? super.dividerColor
        }
    }

    /// A hidden divider takes no space at all, so the panes meet edge to
    /// edge. Painting it to match instead never quite worked: the strip
    /// still sat above a transparent window, and no fill matches glass.
    /// The drag area it would have provided is restored by the delegate's
    /// `additionalEffectiveRectOfDividerAt`.
    override var dividerThickness: CGFloat {
        AppearanceCoordinator.dividerMode.isHidden ? 0 : super.dividerThickness
    }

    /// Drawing the divider directly rather than relying only on the
    /// `dividerColor` override: AppKit does not reliably re-read that
    /// property for an already-drawn divider, so a mode change in settings
    /// left the old divider on screen until the window was recreated.
    /// The divider runs the **full height**, titlebar strip included.
    ///
    /// It used to stop at `safeAreaInsets.top`, to avoid stacking a second
    /// coat over the strip the titlebar paints — the artifact that produced
    /// was a slightly darker tick at the top of the divider. What it produced
    /// instead was worse and was what got reported: the divider simply *ends*
    /// where the titlebar begins, so the line separating the sidebar from the
    /// terminal has a transparent gap in it while the rest of the line is
    /// coloured. A tick a shade too dark reads as a divider; a gap reads as a
    /// bug.
    ///
    /// The clip is gone rather than replaced with `.copy` compositing, which
    /// was the other candidate: `.copy` writes alpha straight through, and
    /// this window is transparent under the glass and blur modes — it would
    /// punch a hole in the strip in exactly the configurations the report asks
    /// not to break.
    ///
    /// Full height minus one point at each extreme: painted to the very
    /// first and last pixel row, the divider ran across the hairline the
    /// window draws along its own top and bottom edges, so a coloured
    /// divider visibly crossed the window's border. A one-point trim keeps
    /// the frame's line intact and — unlike the titlebar-height clip
    /// described above — is too small to read as a gap.
    override func drawDivider(in rect: NSRect) {
        let trimmed = rect.intersection(bounds.insetBy(dx: 0, dy: Self.windowEdgeInset))
        guard !trimmed.isEmpty else { return }

        switch AppearanceCoordinator.dividerMode {
        case .hidden:
            // Nothing to draw: the divider has no width in this mode.
            return
        case .custom(let color):
            color.setFill()
            trimmed.fill()
        case .system:
            if let themed = AppearanceCoordinator.themeDividerColor {
                themed.setFill()
                trimmed.fill()
            } else {
                super.drawDivider(in: trimmed)
            }
        }
    }

    /// How far the divider stays from the window's top and bottom edges,
    /// clearing the border hairline the window draws there.
    static let windowEdgeInset: CGFloat = 1
}
