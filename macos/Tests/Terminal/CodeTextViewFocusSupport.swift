import AppKit
@testable import Ghostty

/// Puts a text view somewhere its key equivalents can reach it.
///
/// `CodeNSTextView.performKeyEquivalent` answers only while the view holds
/// focus. That is the contract the editor's shortcuts are documented with —
/// *"these answer while a file is open and focused, so the terminal keeps its
/// own keys everywhere else"* — and until it was enforced it held only
/// because of where the editor and the terminal happen to sit relative to
/// each other in the view tree.
///
/// A text view built in a test has no window and therefore no focus, so
/// without this every key test would be asserting against the guard instead
/// of against the binding it means to check.
///
/// The window is deliberately never ordered front: showing one hangs the
/// suite, which has no event loop to dismiss it with. `makeFirstResponder`
/// needs no ordering.
@MainActor
enum EditorFocus {
    /// Windows are kept alive for the run. A deallocated one takes
    /// `textView.window` down with it, and the guard would see an unfocused
    /// view again — the failure this helper exists to prevent, arriving by a
    /// different door.
    private static var windows: [NSWindow] = []

    /// A text view set up the way the editor sets one up: focused, and
    /// carrying the shipped bindings.
    ///
    /// Both halves are load-bearing. `CodeNSTextView` answers a key only
    /// through `commandShortcuts`, which `EditorPaneView` fills from the
    /// shortcut store — where every untouched action reports its default. A
    /// view built without that map answers nothing, which is correct and is
    /// exactly what a test meaning to check "⇧⌘F formats" must not do.
    ///
    /// It used to answer anyway, from a hardcoded fallback that fired
    /// whenever the lookup missed — including when the reader had cleared
    /// the shortcut on purpose. Deleting that is what made this helper
    /// necessary.
    @discardableResult
    static func ready(_ textView: CodeNSTextView) -> CodeNSTextView {
        textView.commandShortcuts = Dictionary(
            uniqueKeysWithValues: PhantomShortcutAction.actions(in: .editor).map { action in
                (
                    action.rawValue,
                    action.defaultShortcuts.map {
                        EditorShortcut(key: $0.key, modifiers: $0.eventModifierFlags)
                    }
                )
            })
        return give(to: textView)
    }

    @discardableResult
    static func give(to textView: CodeNSTextView) -> CodeNSTextView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: true)

        window.contentView?.addSubview(textView)
        window.makeFirstResponder(textView)
        windows.append(window)

        return textView
    }
}
