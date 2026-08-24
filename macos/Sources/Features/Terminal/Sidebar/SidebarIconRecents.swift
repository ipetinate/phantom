import AppKit
import Foundation

/// The icons picked most recently, newest first, across every tab and group.
///
/// Called "Recents" because that is what it is ordered by. macOS has two
/// names for a row like this: Finder and the open and save dialogs say
/// "Recents", and the Character Viewer says "Frequently Used". The second
/// one promises a count — the emoji you reach for most, wherever it landed
/// last — and this list keeps no counts at all. Borrowing the label without
/// the frequency would be a small lie the reader can catch: pick a symbol
/// once and watch it outrank the one you have used twenty times.
///
/// Stores whatever was chosen, not just symbol names. The three forms an
/// icon may take share one string — see `SidebarIconID` — and somebody who
/// just picked 🔥 expects to find 🔥 here rather than the last SF Symbol
/// they happened to touch.
struct SidebarIconRecents {
    /// Ten because it is one row and a bit of the picker's seven-column
    /// grid. More than that stops being a shortcut and becomes a second
    /// catalogue to read.
    static let limit = 10

    static let defaultsKey = "SidebarIconRecents"

    /// `list` with `icon` moved to the front, capped, no duplicates.
    ///
    /// Moved, not added: picking something already in the list is the reason
    /// the list exists, and the alternative — a second copy — spends one of
    /// the ten slots saying what the first copy already said. Blank input is
    /// no choice at all, so it changes nothing; the tab editor opens with an
    /// empty icon and saving it must not record one.
    static func recording(_ icon: String, into list: [String]) -> [String] {
        let trimmed = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list }
        return Array(([trimmed] + list.filter { $0 != trimmed }).prefix(limit))
    }

    /// The icons of `list` this build can put on screen.
    ///
    /// A stored list outlives the build that wrote it. An SF Symbol name
    /// from a newer macOS, or an `agent:` id this build does not know, draws
    /// an empty box — and an empty box in a picker is worse than a shorter
    /// row, because the reader cannot tell it from a bug in the sheet.
    static func drawable(_ list: [String]) -> [String] {
        list.filter { icon in
            switch SidebarIconID.kind(of: icon) {
            case .empty, .unknownAgent:
                return false
            case .emoji, .agent:
                return true
            case .symbol:
                return NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil
            }
        }
    }

    private let defaults: UserDefaults

    /// `defaults` is injected so tests can run against a suite of their own.
    /// App code is expected to take the default, the `PhantomShortcutStore`
    /// idiom.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Read straight from the defaults rather than cached, so two sheets
    /// open at once cannot show two different pasts.
    var icons: [String] {
        Self.drawable(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// Called when an editor saves, not when the picker's cell is clicked.
    ///
    /// Clicking around the grid is how you look at it. Recording every cell
    /// the cursor lands on would fill all ten slots with symbols nobody
    /// kept, and would leave a row behind after Cancel — which is the one
    /// gesture that says "none of that".
    func record(_ icon: String) {
        let current = icons
        let updated = Self.recording(icon, into: current)
        guard updated != current else { return }
        defaults.set(updated, forKey: Self.defaultsKey)
    }
}
