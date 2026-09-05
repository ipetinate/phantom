import AppKit
import SwiftUI

struct AgentIconView: View {
    enum Tint {
        case theme
        case brand
    }

    let icon: AgentIcon
    let brandColour: AgentBrandColour
    var size: CGFloat = 12
    var tint: Tint = .theme

    init(_ descriptor: AgentDescriptor, size: CGFloat = 12, tint: Tint = .theme) {
        self.icon = descriptor.icon
        self.brandColour = descriptor.brandColour
        self.size = size
        self.tint = tint
    }

    var body: some View {
        switch tint {
        case .theme:
            template(icon).foregroundStyle(.secondary)
        case .brand:
            brand
        }
    }

    @ViewBuilder
    private var brand: some View {
        switch brandColour {
        case .artwork:
            original(icon)
        case .asset(let name):
            original(.asset(name))
        case .rgb(let red, let green, let blue):
            template(icon).foregroundStyle(Color(.sRGB, red: red, green: green, blue: blue))
        case .label:
            template(icon).foregroundStyle(.primary)
        }
    }

    private func template(_ icon: AgentIcon) -> some View {
        image(icon)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private func original(_ icon: AgentIcon) -> some View {
        image(icon)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.primary)
    }

    private func image(_ icon: AgentIcon) -> Image {
        switch icon {
        case .asset(let name):
            return Image(name)
        case .symbol(let name):
            return Image(systemName: name)
        case .file:
            guard let loaded = AgentIconFiles.shared.image(for: icon) else {
                return Image(systemName: AgentIconFiles.missingSymbol)
            }
            return Image(nsImage: loaded)
        }
    }
}

@MainActor
final class AgentIconFiles {
    static let shared = AgentIconFiles()

    static let missingSymbol = "sparkles"

    private var loaded: [URL: NSImage] = [:]
    private var missing: Set<URL> = []

    static func load(_ icon: AgentIcon) -> NSImage? {
        switch icon {
        case .asset(let name):
            return NSImage(named: name)
        case .symbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .file(let url):
            guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0
            else { return nil }
            return image
        }
    }

    func image(for icon: AgentIcon) -> NSImage? {
        guard case .file(let url) = icon else { return Self.load(icon) }
        if let cached = loaded[url] { return cached }
        guard !missing.contains(url) else { return nil }
        guard let image = Self.load(icon) else {
            missing.insert(url)
            return nil
        }
        loaded[url] = image
        return image
    }
}
