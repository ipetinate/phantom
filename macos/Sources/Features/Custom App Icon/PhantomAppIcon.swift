import AppKit

/// The app icons Phantom ships, and which one is in use.
///
/// Separate from Ghostty's `AppIcon`, which is driven by its own config file
/// (`macos-icon`) and by a colourizer for the ghost artwork. This is Phantom's
/// own set: whole images, chosen in Settings, remembered in `UserDefaults`.
/// Keeping it apart also keeps it out of `GuiConfigStore` — an unknown key in
/// there raises Ghostty's "Configuration Errors" window.
///
/// Every icon here is a flat, hand-delivered render (Figma, not Icon
/// Composer) — one PNG per icon per style, kept in
/// `macos/Resources/PhantomIconVariants/` as `<Icon>-<Style>.png`. Plain
/// images rather than Icon Composer documents: `NSApp.applicationIconImage`
/// and `NSWorkspace.setIcon` — the only way to change a running app's
/// icon — take an `NSImage` and nothing else, so a chooser with more than
/// one icon in it has to be built from renders regardless of what produced
/// them, and Icon Composer's own single-icon-per-bundle pipeline made that
/// exactly one of these renders "special" in a way that stopped being worth
/// the upkeep. `productionDefault`'s render is also what
/// `Assets.xcassets/PhantomAppIcon.appiconset` is generated from, so the
/// compiled-in icon and the picker's own "Default" thumbnail are the same
/// artwork.
///
/// **Adding one is two steps.** Export `<Icon>-Default.png`,
/// `<Icon>-Dark.png` and `<Icon>-Clear.png` into
/// `macos/Resources/PhantomIconVariants/`, and add a case whose raw value is
/// the icon's name. The raw value *is* the file-name stem, so there is no
/// second list to keep in step, and `allCases` drives the picker, the About
/// animation, and everything else.
enum PhantomAppIcon: String, CaseIterable, Identifiable, Codable, Sendable {
    case bullsEye = "Bulls Eye"
    case circuits = "Circuits"
    case standard = "Default"
    case development = "Development"
    case nebula = "Nebula"
    case purpleHaze = "Purple Haze"

    case tributeBullsEye = "Ghostty Tribute Bulls Eye"
    case tributeCircuits = "Ghostty Tribute Circuits"
    case tributeStandard = "Ghostty Tribute Default"
    case tributeDevelopment = "Ghostty Tribute Development"
    case tributeNebula = "Ghostty Tribute Nebula"
    case tributePurpleHaze = "Ghostty Tribute Purple Haze"

    var id: String { rawValue }

    /// Which group the picker shows it under.
    enum Family: String, CaseIterable, Identifiable {
        case phantom
        case ghosttyTribute

        var id: String { rawValue }

        var title: String {
            switch self {
            case .phantom: return "Phantom"
            case .ghosttyTribute: return "Ghostty Tribute"
            }
        }
    }

    /// The prefix that marks a tribute, and the whole of how families are
    /// decided.
    ///
    /// Read from the name rather than declared per case, so adding a tribute
    /// icon needs nothing beyond the case itself — there is no third list to
    /// fall out of step with the assets and the enum.
    static let tributePrefix = "Ghostty Tribute "

    var family: Family {
        rawValue.hasPrefix(Self.tributePrefix) ? .ghosttyTribute : .phantom
    }

    /// What the picker calls it: the name with the family prefix taken off,
    /// since the section header already says it and repeating it in every
    /// row is noise, not information.
    var title: String {
        rawValue.hasPrefix(Self.tributePrefix)
            ? String(rawValue.dropFirst(Self.tributePrefix.count))
            : rawValue
    }

    /// The icons in one family, in declaration order.
    static func all(in family: Family) -> [PhantomAppIcon] {
        allCases.filter { $0.family == family }
    }

    /// The one the app is actually compiled against, and so the one value
    /// `apply(_:)` can skip writing an override for — it is already what is on
    /// disk.
    ///
    /// Its render is also the source for `Assets.xcassets/PhantomAppIcon.appiconset`;
    /// the name differs because the app icon is selected by the
    /// `ASSETCATALOG_COMPILER_APPICON_NAME` build setting, and pointing that
    /// at a file called `Default` would read as a placeholder rather than a
    /// choice.
    static let productionDefault: PhantomAppIcon = .standard

    /// What a build with nothing chosen yet falls back to.
    ///
    /// A local build falls back to `.development`, so it reads as a local
    /// build from the Dock alone — before Settings has even been opened once.
    /// This only decides the *fallback*; picking anything else still sticks
    /// exactly like it does in a release build. See
    /// `PhantomAppIconStore.seedDevelopmentDefaultIfNeeded` for how a fresh
    /// dev environment ends up with that fallback actually persisted rather
    /// than merely computed.
    static var `default`: PhantomAppIcon {
        DevelopmentBuild.isActive ? .development : .productionDefault
    }

    /// Where the rendered exports are bundled.
    static let variantsDirectory = "PhantomIconVariants"

    /// This icon in one style.
    func image(variant: PhantomAppIconVariant) -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: "\(rawValue)-\(variant.fileSuffix)",
            withExtension: "png",
            subdirectory: Self.variantsDirectory
        ) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// This icon in the style currently chosen — what the picker draws and
    /// what gets applied.
    @MainActor
    func image() -> NSImage? {
        image(variant: PhantomAppIconVariantStore.current)
    }
}

/// Reads and writes the chosen icon, and applies it to the running app.
///
/// **Two different icons, and both have to be set.** `NSWorkspace.setIcon`
/// writes the *file's* icon — what Finder shows for the bundle, and what the
/// Dock reads the next time the app is launched. The Dock tile of an app that
/// is *already running* comes from `NSApp.applicationIconImage` instead.
/// Setting only the first is why the choice used to appear on the next launch
/// and not on the click.
///
/// The default icon in its default style is expressed by passing `nil` to
/// both: that *removes* the override and lets the icon compiled into the app
/// show through, rather than writing a copy of it over itself — the two are
/// the same artwork, so this is purely skipping a redundant write, not
/// preserving anything the override couldn't reproduce.
@MainActor
enum PhantomAppIconStore {
    static let defaultsKey = "PhantomAppIcon"

    /// Posted after the icon changes, so anything showing it can catch up.
    static let didChangeNotification = Notification.Name("PhantomAppIconDidChange")

    static var current: PhantomAppIcon {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(PhantomAppIcon.init(rawValue:)) ?? .default
    }

    /// Applies an icon and remembers it, keeping the chosen style.
    @discardableResult
    static func apply(_ icon: PhantomAppIcon) -> Bool {
        UserDefaults.standard.set(icon.rawValue, forKey: defaultsKey)
        return applyCurrent()
    }

    /// Applies a style and remembers it, keeping the chosen icon.
    @discardableResult
    static func apply(_ variant: PhantomAppIconVariant) -> Bool {
        PhantomAppIconVariantStore.set(variant)
        return applyCurrent()
    }

    /// Puts whatever is currently chosen — icon and style together — on the
    /// app.
    @discardableResult
    static func applyCurrent() -> Bool {
        let icon = current

        // No override for the compiled-in pairing: it is already the same
        // artwork, so writing one over it would be a no-op with extra I/O.
        let isCompiledIn = icon == .productionDefault
            && PhantomAppIconVariantStore.current == .default
        let override = isCompiledIn ? nil : icon.image()

        // The running app's Dock tile and ⌘⇥ entry, which change immediately.
        NSApp.applicationIconImage = override

        // And the bundle on disk, so Finder agrees and the next launch starts
        // out right.
        let applied = NSWorkspace.shared.setIcon(override, forFile: Bundle.main.bundlePath)
        // Finder caches icons aggressively; without this the Dock updates and
        // the bundle in a window does not.
        NSWorkspace.shared.noteFileSystemChanged(Bundle.main.bundlePath)

        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        return applied
    }

    /// Re-applies the remembered choice at launch, unconditionally.
    ///
    /// Needed because `setIcon` writes to the bundle, and a rebuild replaces
    /// the bundle — so a fresh build comes up wearing the compiled-in icon
    /// even though a different one was chosen. Unconditional rather than
    /// skipped when the choice already matches the compiled-in default: the
    /// running app's Dock tile (`applicationIconImage`, in memory, gone at
    /// every launch) and the bundle's own custom icon (`setIcon`, on disk,
    /// and able to fail — a read-only volume, a bundle Gatekeeper hasn't
    /// cleared yet) can end up disagreeing about which icon is showing, and
    /// skipping this because "the stored choice is already the default"
    /// says nothing about whether either of *those* actually is. Calling it
    /// every time is one redundant write in the common case in exchange for
    /// never leaving the two out of sync.
    static func restore() {
        seedDevelopmentDefaultIfNeeded()
        applyCurrent()
    }

    /// A dev build with nothing chosen yet starts on the Development icon
    /// instead of wearing what a release would — so a local build is
    /// distinguishable from `/Applications`'s copy from the very first launch,
    /// before Settings has ever been opened.
    ///
    /// Seeds an explicit, *persisted* choice rather than only leaning on what
    /// `PhantomAppIcon.default` computes to: after this runs once,
    /// "Development" is a remembered pick like any other, so choosing a
    /// different icon later behaves exactly like it does in a release build —
    /// nothing here fights that choice on the next launch.
    ///
    /// Checked the same way `current` resolves a stored value — parsed, not
    /// just present — so a name left behind by a renamed or removed case reads
    /// as "nothing meaningfully chosen" rather than as an explicit pick this
    /// must not override.
    private static func seedDevelopmentDefaultIfNeeded() {
        let hasAKnownChoice = UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(PhantomAppIcon.init(rawValue:)) != nil
        guard DevelopmentBuild.isActive, !hasAKnownChoice else { return }
        apply(.development)
    }
}
