import AppKit

enum ExtensionViewerTheme {
    private enum ANSI {
        static let red = 1
        static let green = 2
        static let yellow = 3
        static let blue = 4
        static let white = 7
        static let brightBlack = 8
    }

    static let baseSize = 13.0
    static let codeBackgroundShift: CGFloat = 0.04

    @MainActor
    static func current() -> [String: Any] {
        let palette = ThemePalette.shared
        return make(
            colors: palette.colors,
            background: palette.background,
            uiFont: palette.interfaceFontFamily,
            monoFont: GuiConfigStore.shared.string("font-family") ?? ""
        )
    }

    static func make(colors: [NSColor], background: NSColor?, uiFont: String, monoFont: String) -> [String: Any] {
        var payload: [String: Any] = [
            "scheme": background?.isLightColor ?? false ? "light" : "dark",
            "fonts": ["ui": uiFont, "mono": monoFont],
            "baseSize": baseSize,
        ]
        guard colors.count >= 16 else { return payload }

        let backgroundColor = background ?? .textBackgroundColor
        payload["colors"] = [
            "bg": hex(backgroundColor),
            "fg": hex(colors[ANSI.white]),
            "accent": hex(colors[ANSI.blue]),
            "muted": hex(mixed(colors[ANSI.white], towards: backgroundColor, fraction: mutedMix)),
            "border": hex(mixed(backgroundColor, towards: colors[ANSI.white], fraction: borderMix)),
            "codeBg": hex(shifted(backgroundColor)),
            "danger": hex(colors[ANSI.red]),
            "warning": hex(colors[ANSI.yellow]),
            "success": hex(colors[ANSI.green]),
        ]
        return payload
    }

    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            .map { max(0, min(255, Int(($0 * 255).rounded()))) }
        return String(format: "#%02x%02x%02x", channels[0], channels[1], channels[2])
    }

    static let mutedMix: CGFloat = 0.45
    static let borderMix: CGFloat = 0.14

    static func mixed(_ color: NSColor, towards other: NSColor, fraction: CGFloat) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB), let target = other.usingColorSpace(.sRGB) else { return color }
        return rgb.blended(withFraction: fraction, of: target) ?? rgb
    }

    static func shifted(_ background: NSColor) -> NSColor {
        guard let rgb = background.usingColorSpace(.sRGB) else { return background }
        let towards: NSColor = rgb.isLightColor ? .black : .white
        return rgb.blended(withFraction: codeBackgroundShift, of: towards) ?? rgb
    }

    static func json(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
