import SwiftUI

// All backport view/scene modifiers go as an extension on this. We use this
// so we can easily track and centralize all backports.
struct Backport<Content> {
    let content: Content
}

extension View {
    var backport: Backport<Self> { Backport(content: self) }
}

extension Scene {
    var backport: Backport<Self> { Backport(content: self) }
}

extension Backport where Content: Scene {
    // None currently
}

/// Result type for backported onKeyPress handler
enum BackportKeyPressResult {
    case handled
    case ignored
}

/// A key press delivered to a focused view: which key, and which
/// modifiers were held with it.
struct BackportKeyPress {
    let key: Character
    let modifiers: EventModifiers
    let characters: String?
}

extension Backport where Content: View {
    func pointerVisibility(_ v: BackportVisibility) -> some View {
        #if canImport(AppKit)
        if #available(macOS 15, *) {
            return content.pointerVisibility(v.official)
        } else {
            return content
        }
        #else
        return content
        #endif
    }

    func pointerStyle(_ style: BackportPointerStyle?) -> some View {
        #if canImport(AppKit)
        if #available(macOS 15, *) {
            return content.pointerStyle(style?.official)
        } else {
            return content
        }
        #else
        return content
        #endif
    }

    /// Drops the system focus ring while leaving the view focusable.
    ///
    /// The two are separate needs and SwiftUI ties them together: a view has
    /// to be `focusable()` to receive key presses, and being focusable is
    /// what draws the ring. Somewhere like the file tree — which answers
    /// arrow keys and shortcuts, but is a sidebar list rather than a control
    /// — the keyboard behavior is wanted and the blue outline around the
    /// whole box is not.
    ///
    /// A no-op on macOS 13, where the modifier doesn't exist; the ring stays,
    /// which is the pre-existing behavior rather than a regression.
    func focusEffectDisabled() -> some View {
        #if canImport(AppKit)
        if #available(macOS 14, *) {
            return content.focusEffectDisabled()
        } else {
            return content
        }
        #else
        return content
        #endif
    }

    /// Backported onKeyPress that works on macOS 14+ and is a no-op on macOS 13.
    func onKeyPress(_ key: KeyEquivalent, action: @escaping (EventModifiers) -> BackportKeyPressResult) -> some View {
        #if canImport(AppKit)
        if #available(macOS 14, *) {
            return content.onKeyPress(key, phases: .down, action: { keyPress in
                switch action(keyPress.modifiers) {
                case .handled: return .handled
                case .ignored: return .ignored
                }
            })
        } else {
            return content
        }
        #else
        return content
        #endif
    }

    /// Backported free-form onKeyPress that works on macOS 14+ and is a
    /// no-op on macOS 13. Unlike the keyed variant this reports *which* key
    /// was pressed, which is what a user-configurable shortcut needs.
    func onKeyPress(_ action: @escaping (BackportKeyPress) -> BackportKeyPressResult) -> some View {
        #if canImport(AppKit)
        if #available(macOS 14, *) {
            return content.onKeyPress(phases: .down, action: { press in
                switch action(BackportKeyPress(
                    key: press.key.character,
                    modifiers: press.modifiers,
                    characters: press.characters
                )) {
                case .handled: return .handled
                case .ignored: return .ignored
                }
            })
        } else {
            return content
        }
        #else
        return content
        #endif
    }
}

enum BackportVisibility {
    case automatic
    case visible
    case hidden

    @available(macOS 15, *)
    var official: Visibility {
        switch self {
        case .automatic: return .automatic
        case .visible: return .visible
        case .hidden: return .hidden
        }
    }
}

enum BackportPointerStyle {
    case `default`
    case grabIdle
    case grabActive
    case horizontalText
    case verticalText
    case link
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case resizeUpDown
    case resizeLeftRight

    #if canImport(AppKit)
    @available(macOS 15, *)
    var official: PointerStyle {
        switch self {
        case .default: return .default
        case .grabIdle: return .grabIdle
        case .grabActive: return .grabActive
        case .horizontalText: return .horizontalText
        case .verticalText: return .verticalText
        case .link: return .link
        case .resizeLeft: return .columnResize(directions: .leading)
        case .resizeRight: return .columnResize(directions: .trailing)
        case .resizeUp: return .rowResize(directions: .up)
        case .resizeDown: return .rowResize(directions: .down)
        case .resizeUpDown: return .rowResize
        case .resizeLeftRight: return .columnResize
        }
    }
    #endif
}

enum BackportNSGlassStyle {
    case regular, clear

    #if canImport(AppKit)
    @available(macOS 26, *)
    var official: NSGlassEffectView.Style {
        switch self {
        case .regular: return .regular
        case .clear: return .clear
        }
    }
    #endif
}

/// Backported `TextField` that supports text selection on macOS 15/iOS 18 and up. The `selection`
/// has no effect on versions below macOS 15/iOS 18.
struct BackportSelectionTextField: View {
    private let titleKey: LocalizedStringKey
    @Binding private var text: String
    @Binding private var textSelection: Range<String.Index>?

    init(
        _ titleKey: LocalizedStringKey,
        text: Binding<String>,
        selection: Binding<Range<String.Index>?>
    ) {
        self.titleKey = titleKey
        self._text = text
        self._textSelection = selection
    }

    var body: some View {
        if #available(iOS 18.0, macOS 15, *) {
            TextField(
                titleKey,
                text: _text,
                selection: Binding(
                    get: {
                        if let textSelection {
                            TextSelection(range: textSelection)
                        } else {
                            nil
                        }
                    },
                    set: { selection in
                        if let selection,
                           case .selection(let range) = selection.indices {
                            self.textSelection = range
                        } else {
                            self.textSelection = nil
                        }
                    }
                )
            )
        } else {
            TextField(titleKey, text: _text)
        }
    }
}
