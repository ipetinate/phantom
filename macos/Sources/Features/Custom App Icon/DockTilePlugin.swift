import AppKit

/// Draws the chosen app icon on the Dock tile while Phantom is not running.
///
/// This is the half of the icon choice that `NSApp.applicationIconImage`
/// cannot cover: that property is in-memory and dies with the process, so a
/// pinned Phantom in the Dock would fall back to the compiled-in icon the
/// moment the app quits. The dock tile plugin is Apple's mechanism for
/// exactly this gap — the Dock loads it for a pinned, not-running app — and
/// it is what lets the icon choice persist without ever writing into the
/// signed bundle (see `PhantomAppIconStore` for why that write is banned).
///
/// This code runs inside the Dock's process, not Phantom's, which shapes
/// everything here:
///
/// - `Bundle.main` is the Dock. The app bundle is found by walking up from
///   this plugin's own location — `Phantom.app/Contents/PlugIns/…` — so the
///   plugin works wherever the app is installed, and a debug build (whose
///   bundle id differs) reads its own defaults domain rather than the
///   release app's.
/// - The choice is read straight from the two defaults keys as raw strings.
///   The `PhantomAppIcon` enums are compiled into the app target, not this
///   plugin, and sharing them would drag `Bundle.main`-relative resource
///   lookups into a process where `Bundle.main` is wrong. The filename
///   contract is the one `PhantomAppIcon` documents: one
///   `<Icon>-<Style>.png` per pairing under `PhantomIconVariants/`.
/// - The tile is read once per `setDockTile` call, which the Dock makes
///   when the tile appears. A choice made while the app runs shows on the
///   running app's own tile; the pinned tile catches up the next time the
///   Dock rebuilds it.
class DockTilePlugin: NSObject, NSDockTilePlugIn {
    /// The two keys `PhantomAppIconStore` and `PhantomAppIconVariantStore`
    /// persist. Raw strings on purpose — see the type comment.
    private static let iconKey = "PhantomAppIcon"
    private static let variantKey = "PhantomAppIconVariant"
    private static let compiledInIcon = "Default"
    private static let compiledInVariant = "Default"
    private static let variantsDirectory = "PhantomIconVariants"

    func setDockTile(_ dockTile: NSDockTile?) {
        guard let dockTile else { return }

        guard let image = Self.chosenOverrideImage() else {
            // No override chosen (or nothing readable): the default tile is
            // the compiled-in icon, which is exactly right.
            dockTile.contentView = nil
            dockTile.display()
            return
        }

        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        dockTile.contentView = view
        dockTile.display()
    }

    /// The app bundle this plugin is embedded in:
    /// `…/Phantom.app/Contents/PlugIns/DockTilePlugin.plugin` → `…/Phantom.app`.
    private static var appBundle: Bundle? {
        let pluginURL = Bundle(for: DockTilePlugin.self).bundleURL
        let appURL = pluginURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Phantom.app
        return Bundle(url: appURL)
    }

    /// The chosen artwork, or nil when the compiled-in icon should show.
    ///
    /// Read through `CFPreferences`, the API for reading another
    /// application's defaults domain by id — which is what the app's
    /// `UserDefaults.standard` is from where this code runs.
    private static func chosenOverrideImage() -> NSImage? {
        guard let appBundle, let bundleID = appBundle.bundleIdentifier
        else { return nil }

        func stored(_ key: String) -> String? {
            CFPreferencesCopyAppValue(key as CFString, bundleID as CFString) as? String
        }

        let icon = stored(iconKey) ?? compiledInIcon
        let variant = stored(variantKey) ?? compiledInVariant
        guard icon != compiledInIcon || variant != compiledInVariant else { return nil }

        guard let url = appBundle.url(
            forResource: "\(icon)-\(variant)",
            withExtension: "png",
            subdirectory: variantsDirectory
        ) else { return nil }
        return NSImage(contentsOf: url)
    }
}
