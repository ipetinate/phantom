import AppKit

/// Deliberately does nothing.
///
/// Upstream Ghostty uses this to paint its own alternate-icon system (and,
/// in debug builds, a hardcoded "Blueprint" badge to tell debug apart from
/// release) directly onto the Dock tile — a second icon authority racing
/// `PhantomAppIconStore`'s. Phantom has its own answer to "which icon, and
/// how do I tell a dev build apart" (`PhantomAppIcon.default`, seeded to
/// `.development`), so this plugin is kept only because removing the whole
/// target is more surgery than the payoff justifies — an untouched Dock
/// tile just shows whatever `NSApp.applicationIconImage` already is.
class DockTilePlugin: NSObject, NSDockTilePlugIn {
    func setDockTile(_ dockTile: NSDockTile?) {}
}
