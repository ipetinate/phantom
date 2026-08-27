import AppKit

/// One line of text that appears beside the caret and takes itself away.
///
/// ## Why this exists at all
///
/// ⌃Space could fail four different ways and every one of them looked
/// identical from the reader's chair: nothing happened. Completions switched
/// off, switched off for this language, a server with nothing to say, a list
/// built and then declined by a panel that had no rectangle to anchor to —
/// four causes, one symptom, and the symptom is also exactly what an unbound
/// key looks like. So the editor could not be debugged by the person using
/// it, and the report it produced was "⌃Space does nothing", which is true
/// and says nothing about which of the four it was.
///
/// This is the answer to that. An explicit request that cannot produce a list
/// says why instead of returning quietly.
///
/// ## Why it is not a menu
///
/// A menu was the first shape, and it is the wrong one: `NSMenu` tracking
/// swallows the keyboard for as long as it is up. A reader who presses ⌃Space
/// and carries on typing would have lost the next second and a half of their
/// keystrokes to a notice telling them nothing happened, which is a good deal
/// worse than the silence it replaced.
///
/// So: a non-activating panel that never becomes key, on the same terms as
/// `CodeCompletionPanel` — the caret keeps blinking, the text view keeps the
/// keyboard, and typing dismisses this rather than being eaten by it.
final class CodeNoticePanel: NSPanel {
    /// How long it stays up when nothing dismisses it first.
    ///
    /// Long enough to read six words, short enough that nobody reaches for
    /// the mouse.
    static let lifetime: Duration = .milliseconds(1800)

    private let label = NSTextField(labelWithString: "")
    private let card = NSView()
    private var timeout: Task<Void, Never>?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating

        card.wantsLayer = true
        card.layer?.cornerRadius = 6
        card.layer?.borderWidth = 1

        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
        ])

        contentView = card
    }

    /// Never. Taking key status here would stop the caret blinking and pull
    /// the arrow keys out of the text view — for a label. See
    /// `CodeCompletionPanel`, which carries the same line and the same
    /// warning against "unifying" it with the hover card.
    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    /// Puts one line under the caret.
    ///
    /// - Parameter anchor: the caret's rectangle in **screen** coordinates. A
    ///   zero-height one means the line has not been laid out, and nothing is
    ///   drawn rather than a panel in the corner of the display.
    func show(
        _ text: String,
        theme: CodeTheme,
        font: NSFont,
        anchor: NSRect,
        over view: NSView
    ) {
        guard !text.isEmpty, anchor.height > 0, let parentWindow = view.window else {
            dismiss()
            return
        }

        label.stringValue = text
        label.font = .systemFont(ofSize: max(11, font.pointSize - 1))
        label.textColor = theme.foreground.withAlphaComponent(0.85)
        card.layer?.backgroundColor = theme.background.cgColor
        card.layer?.borderColor = theme.lineNumber.withAlphaComponent(0.35).cgColor

        let size = card.fittingSize
        setContentSize(size)
        setFrameOrigin(PanelPlacement.origin(
            anchor: anchor,
            size: size,
            visible: (parentWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero,
            prefers: .below
        ))

        if parent == nil { parentWindow.addChildWindow(self, ordered: .above) }
        orderFront(nil)
        invalidateShadow()

        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        timeout?.cancel()
        timeout = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}
