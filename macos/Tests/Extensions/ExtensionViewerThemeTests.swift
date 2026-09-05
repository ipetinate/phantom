import AppKit
@testable import Ghostty
import Testing

struct ExtensionViewerThemeTests {
    private static let dracula = [
        "#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
        "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF",
    ]

    private func color(_ hex: String) -> NSColor {
        let scanner = Scanner(string: String(hex.dropFirst()))
        var value: UInt64 = 0
        _ = scanner.scanHexInt64(&value)
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }

    private var palette: [NSColor] { Self.dracula.map(color) }

    private func colorMap(of payload: [String: Any]) -> [String: String]? {
        payload["colors"] as? [String: String]
    }

    @Test func aSixteenColorPaletteMapsToHexSlots() throws {
        let payload = ExtensionViewerTheme.make(
            colors: palette, background: color("#060608"), uiFont: "Inter", monoFont: "JetBrains Mono")

        #expect(payload["scheme"] as? String == "dark")
        #expect(payload["baseSize"] as? Double == 13)
        #expect(payload["fonts"] as? [String: String] == ["ui": "Inter", "mono": "JetBrains Mono"])

        let colors = try #require(colorMap(of: payload))
        #expect(colors["bg"] == "#060608")
        #expect(colors["fg"] == "#f8f8f2")
        #expect(colors["accent"] == "#bd93f9")
        #expect(colors["danger"] == "#ff5555")
        #expect(colors["warning"] == "#f1fa8c")
        #expect(colors["success"] == "#50fa7b")
        #expect(colors["muted"] == "#6272a4")
        #expect(colors["border"] == "#6272a4")
        #expect(colors.count == 9)
    }

    @Test func theCodeBackgroundShiftsAwayFromTheBackground() {
        #expect(ExtensionViewerTheme.hex(ExtensionViewerTheme.shifted(color("#000000"))) == "#0a0a0a")
        #expect(ExtensionViewerTheme.hex(ExtensionViewerTheme.shifted(color("#ffffff"))) == "#f5f5f5")

        let dark = ExtensionViewerTheme.make(colors: palette, background: color("#060608"), uiFont: "", monoFont: "")
        let darkColors = colorMap(of: dark)
        #expect(darkColors?["codeBg"] != darkColors?["bg"])
    }

    @Test func aLightBackgroundReadsAsALightScheme() {
        let light = ExtensionViewerTheme.make(colors: palette, background: color("#fafafa"), uiFont: "", monoFont: "")
        #expect(light["scheme"] as? String == "light")
        #expect(colorMap(of: light)?["bg"] == "#fafafa")

        let unknown = ExtensionViewerTheme.make(colors: [], background: nil, uiFont: "", monoFont: "")
        #expect(unknown["scheme"] as? String == "dark")
    }

    @Test func aShortPaletteCarriesNoColors() {
        let empty = ExtensionViewerTheme.make(colors: [], background: color("#060608"), uiFont: "Inter", monoFont: "")
        #expect(empty["colors"] == nil)
        #expect(empty["scheme"] as? String == "dark")
        #expect(empty["fonts"] as? [String: String] == ["ui": "Inter", "mono": ""])

        let short = ExtensionViewerTheme.make(colors: Array(palette.prefix(8)), background: nil, uiFont: "", monoFont: "")
        #expect(short["colors"] == nil)
    }

    @Test func hexIsLowercaseAndSixDigits() {
        #expect(ExtensionViewerTheme.hex(color("#FF5555")) == "#ff5555")
        #expect(ExtensionViewerTheme.hex(color("#000000")) == "#000000")
        #expect(ExtensionViewerTheme.hex(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)) == "#ffffff")
    }

    @Test func thePayloadSerializesToJSONWithSortedKeys() {
        let payload = ExtensionViewerTheme.make(colors: [], background: nil, uiFont: "Inter", monoFont: "Menlo")
        #expect(ExtensionViewerTheme.json(payload) == "{\"baseSize\":13,\"fonts\":{\"mono\":\"Menlo\",\"ui\":\"Inter\"},\"scheme\":\"dark\"}")
        #expect(ExtensionViewerTheme.json(["bad": Date()]) == "{}")
    }
}
