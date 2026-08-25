import AppKit

/// The row of choices over one conflict.
///
/// A plain `NSView` of `NSButton`s, added as a subview of the text view rather
/// than drawn by it. Being a subview of the document is what makes it scroll
/// with the text for free: the clip view scrolls by moving its bounds, so a
/// bar pinned to a line stays on that line without anybody observing a scroll.
///
/// It sits at the trailing edge of the `<<<<<<<` line rather than over it. The
/// marker line is the one place in the block with nothing worth reading — but
/// it does carry the branch name, and a bar laid across it would take that
/// away for no gain.
final class EditorConflictBar: NSView {
    /// Which conflict this belongs to, by position in the file. Not an index
    /// into anything: the bars are rebuilt whenever the text moves.
    let conflictID: Int

    private let onChoose: (EditorConflict.Choice) -> Void

    init(
        conflict: EditorConflict,
        font: NSFont,
        onChoose: @escaping (EditorConflict.Choice) -> Void
    ) {
        self.conflictID = conflict.id
        self.onChoose = onChoose
        super.init(frame: .zero)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        for choice in conflict.choices {
            stack.addArrangedSubview(button(for: choice, font: font))
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func button(for choice: EditorConflict.Choice, font: NSFont) -> NSButton {
        let button = NSButton(title: choice.title, target: self, action: #selector(chose(_:)))
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: max(9, min(12, font.pointSize - 2)))
        button.identifier = NSUserInterfaceItemIdentifier(choice.rawValue)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    @objc private func chose(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let choice = EditorConflict.Choice(rawValue: raw)
        else { return }
        onChoose(choice)
    }

    /// The size the row wants, so the caller can right-align it without
    /// knowing what is in it.
    var preferredSize: NSSize { fittingSize }
}
