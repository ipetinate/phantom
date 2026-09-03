import AppKit
import SwiftUI

/// A group of tabs shown as a section in the sidebar.
///
/// Groups come in two kinds: manual groups the user creates and assigns
/// tabs to freely, and project groups that automatically claim any tab
/// whose working directory lives under the project root.
struct SidebarGroup: Identifiable, Codable, Equatable {
    /// How tabs become members of a group.
    enum Kind: Codable, Equatable {
        /// Tabs are assigned explicitly by the user.
        case manual

        /// Tabs whose pwd is inside `root` belong to this group.
        case project(root: String)
    }

    let id: UUID
    var name: String

    /// Optional secondary line rendered under the name in the header.
    var details: String?

    /// A single emoji or an SF Symbol name. `SidebarGroupIcon` resolves
    /// which of the two it is at render time.
    var icon: String

    var color: TerminalTabColor

    /// A theme-palette (or otherwise custom) color; wins over `color`.
    var colorHex: String?

    var collapsed: Bool
    var kind: Kind

    /// The project root for a project group, nil for a manual one.
    ///
    /// This is what lets an *empty* project group still offer "New Terminal
    /// in Worktree": with no tabs there is no representative tab to borrow a
    /// repo from, and the button used to hide exactly when a group most
    /// needs it — before its first terminal exists. A manual group names no
    /// repository, so nil is the honest answer there and the button stays
    /// hidden.
    var projectRoot: String? {
        if case .project(let root) = kind { return root }
        return nil
    }

    /// The effective accent: custom hex first, then the preset color.
    var accentColor: Color? {
        if let colorHex, let nsColor = NSColor(hex: colorHex) {
            return Color(nsColor: nsColor)
        }
        return color.sidebarAccent
    }

    init(
        id: UUID = UUID(),
        name: String,
        details: String? = nil,
        icon: String = "folder",
        color: TerminalTabColor = .none,
        collapsed: Bool = false,
        kind: Kind = .manual
    ) {
        self.id = id
        self.name = name
        self.details = details
        self.icon = icon
        self.color = color
        self.collapsed = collapsed
        self.kind = kind
    }

    /// Whether a tab with the given pwd is claimed by this group's project rule.
    func claims(pwd: String?) -> Bool {
        guard case .project(let root) = kind else { return false }
        guard let pwd, !pwd.isEmpty else { return false }
        let normalizedRoot = (root as NSString).expandingTildeInPath
        return pwd == normalizedRoot || pwd.hasPrefix(normalizedRoot + "/")
    }

    /// Every git repository at or under a project group's root.
    ///
    /// A project group's root is often a *workspace* — a plain folder that
    /// holds several repos side by side (`~/Projects/Acme/acme-backend`,
    /// `.../acme-web`) — rather than a repo itself. Only tabs whose pwd
    /// happens to be open inside one of those repos showed up in the group's
    /// PR list before; a repo nobody has a tab open in didn't, even though it
    /// belongs to the group just as much.
    ///
    /// Bounded to a shallow walk (workspace / repo, or workspace / team /
    /// repo) so this stays a quick popover-open check rather than a real
    /// filesystem crawl, and stops descending the moment a repo is found —
    /// a discovered repo's own contents (which can be enormous) are never
    /// looked inside.
    nonisolated static func discoverRepoRoots(
        under root: String,
        maxDepth: Int = 2
    ) -> [String] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)

        func isRepo(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent(".git").path)
        }

        func scan(_ url: URL, depth: Int) -> [String] {
            if isRepo(url) { return [url.path] }
            guard depth < maxDepth,
                  let entries = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  )
            else { return [] }

            return entries.flatMap { entry -> [String] in
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { return [] }
                return scan(entry, depth: depth + 1)
            }
        }

        return scan(rootURL, depth: 0)
    }
}

/// Resolves a group icon string into a SwiftUI view: an agent's own mark, a
/// single-grapheme non-ASCII string as emoji text, anything else as an SF
/// Symbol.
struct SidebarGroupIcon: View {
    let icon: String
    var size: CGFloat = 12

    /// The fallback for the two cases with no icon of their own to draw.
    ///
    /// `unknownAgent` used to reach `Image(systemName:)` with the whole
    /// `agent:aider` string and draw an empty box — the thing `SidebarIconID`
    /// says it exists to prevent. An unfamiliar agent gets the same plain
    /// folder an unset icon does.
    private static let fallback = "folder"

    var body: some View {
        switch SidebarIconID.kind(of: icon) {
        case .agent(let agent):
            agentMark(agent)
        case .emoji:
            Text(icon)
                .font(.system(size: size))
        case .empty, .unknownAgent:
            Image(systemName: Self.fallback)
                .font(.system(size: size - 1, weight: .medium))
        case .symbol:
            Image(systemName: icon)
                .font(.system(size: size - 1, weight: .medium))
        }
    }

    /// Drawn in the agents' own colours rather than tinted with everything
    /// else on the row.
    ///
    /// The point of choosing one of these is to recognise it at a glance in a
    /// list of twenty tabs, and a brand mark flattened to the secondary label
    /// colour is three grey shapes that look alike. It is the same call the
    /// Settings rows already make, where each agent's toggle carries its mark
    /// in colour.
    private func agentMark(_ agent: CodingAgent) -> some View {
        AgentBrandMark(agent: agent, size: size)
    }
}

extension TerminalTabColor {
    /// The group accent color for sidebar tinting, nil when `.none`.
    var sidebarAccent: Color? {
        guard let nsColor = displayColor else { return nil }
        return Color(nsColor: nsColor)
    }

    /// A small filled-circle swatch for menu rows, where SF Symbols
    /// render as templates and lose their tint.
    var menuSwatch: NSImage {
        Self.menuSwatch(for: displayColor)
    }

    static func menuSwatch(for color: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if let color {
                color.setFill()
                circle.fill()
            } else {
                NSColor.tertiaryLabelColor.setStroke()
                circle.lineWidth = 1.2
                circle.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The current theme's palette, shared app-wide so color pickers can
/// offer theme colors next to the preset ones. Reloads whenever the
/// GUI settings apply (theme switches, config reloads).
@MainActor
final class ThemePalette: ObservableObject {
    static let shared = ThemePalette()

    @Published private(set) var colors: [NSColor] = []
    @Published private(set) var background: NSColor?

    /// Phantom's interface font (see `AppFont`), mirrored here so the
    /// sidebar's rows can react to it: they already pin their own size per
    /// role, which is exactly what makes them invisible to the environment
    /// default `.interfaceFont()` applies — this is the escape hatch that
    /// still lets a fixed-size row honor the family.
    @Published private(set) var interfaceFontFamily: String = ""

    /// The theme's primary/accent swatch — ANSI index 4 (Blue) by
    /// convention, matching the accent already used in theme previews.
    var primary: NSColor? { colors.count > 4 ? colors[4] : nil }

    /// The accent for app controls, so a selection in settings is the same
    /// colour as a selection in the sidebar rather than the system's.
    var accent: Color? {
        primary.map { Color(nsColor: $0) }
    }

    /// ANSI index 5 (Magenta) — the "waiting for input" hand colour, kept
    /// distinct from the blue accent so the two attention signals read
    /// differently.
    var magenta: Color? {
        colors.count > 5 ? Color(nsColor: colors[5]) : nil
    }

    /// ANSI index 3 (Yellow) — "busy, and not an error". The one state that
    /// needs to read as neither the blue of a normal turn nor the red of a
    /// failure, and a theme's yellow is chosen for exactly that reading.
    var yellow: Color? {
        colors.count > 3 ? Color(nsColor: colors[3]) : nil
    }

    /// ANSI index 1 (Red) — the theme's own danger colour, so a destructive
    /// control warms to the palette the reader chose instead of to the one
    /// SwiftUI ships. Themes are picked for their reds as much as anything
    /// else; a system red beside a Dracula sidebar reads as a foreign object.
    var danger: Color? {
        colors.count > 1 ? Color(nsColor: colors[1]) : nil
    }

    /// Whether the theme reads as light, which decides whether app windows
    /// take light or dark chrome regardless of the system setting.
    var isLightBackground: Bool {
        background?.isLightColor ?? false
    }

    static let ansiNames = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
        "Bright Black", "Bright Red", "Bright Green", "Bright Yellow",
        "Bright Blue", "Bright Magenta", "Bright Cyan", "Bright White",
    ]

    private var observer: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?

    init() {
        reload()
        interfaceFontFamily = UserDefaults.standard.string(forKey: AppFont.interfaceFamilyKey) ?? ""
        observer = NotificationCenter.default.addObserver(
            forName: GuiConfigStore.didApply,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadInterfaceFontFamily() }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func reload() {
        let store = GuiConfigStore.shared
        guard let url = store.currentThemeURL,
              let theme = ThemeCatalog.parse(url: url, source: .user)
        else {
            colors = []
            background = nil
            return
        }

        colors = (0..<16).compactMap { theme.palette[$0] }
        background = theme.background
    }

    private func reloadInterfaceFontFamily() {
        let value = UserDefaults.standard.string(forKey: AppFont.interfaceFamilyKey) ?? ""
        if value != interfaceFontFamily { interfaceFontFamily = value }
    }

    /// A system-style font at `size`, honoring the interface font override
    /// for chrome that pins its own size per role (the sidebar) — text that
    /// does that never sees `.interfaceFont()`'s environment default, since
    /// an explicit `.font()` on a view always wins over the environment.
    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard !interfaceFontFamily.isEmpty else { return .system(size: size, weight: weight) }
        return .custom(interfaceFontFamily, size: size).weight(weight)
    }

    /// Matches macOS's `.caption` at the size the sidebar already assumed.
    var captionFont: Font { font(size: 11) }

    /// Matches macOS's `.headline`.
    var headlineFont: Font { font(size: 13, weight: .semibold) }
}
