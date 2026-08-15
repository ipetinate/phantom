import AppKit
import CoreText
import OSLog

/// The bundled Codicons font, activated for this process.
///
/// **This lives outside `Editor/Engine/` because of one line: `Bundle.main`.**
/// The engine takes what it needs as values — a theme arrives as `CodeTheme`,
/// a font arrives as an `NSFont` — and a component that goes looking through
/// the host's bundle for a resource cannot be handed to a different host, which
/// is the promise `EditorEngineBoundaryTests` exists to keep. So the lookup and
/// the activation happen here, and `CodeCompletionPanel.iconFont` receives the
/// result.
///
/// Every path through this returns nil rather than throwing or trapping, and
/// nil is a supported outcome all the way down: the panel falls back to SF
/// Symbols, which every kind still names. A missing font costs the list its
/// Codicons and nothing else.
enum CompletionIconFont {
    /// The font's own PostScript name, which is lowercase.
    ///
    /// AppKit's lookup is case-insensitive so `Codicon` resolves too, but this
    /// is what the file declares — verified by reading
    /// `kCTFontNameAttribute` off the descriptor rather than by guessing from
    /// the filename, which is how a font name is usually got wrong.
    static let fontName = "codicon"

    /// `Resources/codicons/` in the source tree, which the Xcode project
    /// carries as a folder reference — so the built app has
    /// `Contents/Resources/codicons/`, with the font's licence and its
    /// attribution notice beside it. Both are a condition of shipping the
    /// glyphs at all; see that folder's `README.md`.
    static let directory = "codicons"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "CompletionIconFont"
    )

    /// Registration runs once, on first use, because `static let` is lazy and
    /// its initialisation is already made thread-safe by the runtime — which is
    /// the whole reason it is a stored property rather than a function anyone
    /// could call twice. `CTFontManagerRegisterFontsForURL` reports an
    /// already-registered file as a failure, so a second call would answer
    /// "no font" about a font that is loaded and working.
    private static let isRegistered = register()

    /// The font at `size`, or nil if the resource is missing or would not
    /// register.
    static func font(ofSize size: CGFloat) -> NSFont? {
        guard isRegistered else { return nil }
        return NSFont(name: fontName, size: size)
    }

    private static func register() -> Bool {
        guard let url = Bundle.main.url(
            forResource: "codicon",
            withExtension: "ttf",
            subdirectory: directory
        ) else {
            logger.warning("codicon.ttf is not in the bundle; the completion list will use SF Symbols")
            return false
        }

        /// `.process` rather than `.user` or `.persistent`: this font is for
        /// drawing one column of one list, and the other two scopes put it in
        /// the font list of every app the person runs — a side effect nobody
        /// asked an editor for, and one that outlives the process that caused
        /// it.
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            logger.warning("codicon.ttf failed to register: \(String(describing: error?.takeRetainedValue()))")
            return false
        }
        return true
    }
}
