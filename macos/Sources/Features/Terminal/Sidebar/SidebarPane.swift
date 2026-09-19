import Combine
import SwiftUI

/// One panel the sidebar can show.
///
/// The sidebar started out only able to list terminals. This type is the
/// seam that lets it hold more: adding a built-in panel is a `static let`
/// here plus a branch in `SidebarView.paneContent` and, if it needs its own
/// titlebar buttons, one in `SidebarTitlebarChrome`. Nothing in the AppKit
/// hierarchy (`TerminalController.makeSidebarSplitView`) has to change.
///
/// **A struct rather than an enum**, and the reason is the whole of
/// `contributes.views`: an extension puts a button in the two bars, so the
/// set of entries is not known at compile time and cannot be `CaseIterable`.
/// The built-ins keep the spelling they had — `.terminals`, `.git` — because
/// a static member of an `Equatable` type matches in a `switch` the way a
/// case does; what a `switch` over this now needs is a `default`.
///
/// A contributed entry is not a panel. It never becomes `selectedPane`: its
/// page opens as a tab of the editor. What it needs from this type is an
/// identity to hang a `UserDefaults` key off, so the reader can take its
/// button out of the bars.
struct SidebarPane: RawRepresentable, Hashable, Identifiable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let terminals = SidebarPane(rawValue: "terminals")
    static let files = SidebarPane(rawValue: "files")
    static let git = SidebarPane(rawValue: "git")
    static let worktrees = SidebarPane(rawValue: "worktrees")
    static let extensions = SidebarPane(rawValue: "extensions")
    static let orchestrator = SidebarPane(rawValue: "orchestrator")

    /// The panels this build ships, in tab order.
    static let builtIns: [SidebarPane] = [.terminals, .files, .git, .worktrees, .extensions, .orchestrator]

    /// What a contributed entry's `rawValue` begins with.
    ///
    /// A colon, which `LanguageManifest.validID` refuses in an extension id
    /// and `LanguageContribution.validLanguageID` refuses in a view id — so
    /// no contributed entry can ever spell a built-in's raw value, and no
    /// built-in can be mistaken for a contributed one.
    static let viewPrefix = "view:"

    /// The bars' entry for an extension's view.
    static func view(_ id: String) -> SidebarPane {
        SidebarPane(rawValue: viewPrefix + id)
    }

    /// The `ExtensionViewDescriptor.id` this entry opens, or nil for a
    /// built-in.
    var contributedViewID: String? {
        guard rawValue.hasPrefix(Self.viewPrefix) else { return nil }
        let id = String(rawValue.dropFirst(Self.viewPrefix.count))
        return id.isEmpty ? nil : id
    }

    var id: String { rawValue }

    /// The built-in's name. A contributed entry's name is its manifest's
    /// `title` and travels on `SidebarPaneItem`, because it is a third
    /// party's string and this type is not where escaping belongs.
    var title: String {
        switch self {
        case .terminals: return "Terminals"
        case .files: return "Files"
        case .git: return "Git"
        case .worktrees: return "Worktrees"
        case .extensions: return "Extensions"
        case .orchestrator: return "Agents Manager"
        default: return contributedViewID ?? rawValue
        }
    }

    /// SF Symbol for the tab bar, or nil for a panel that ships its own
    /// artwork (see `SidebarPaneIcon`) — git, worktrees and every
    /// contributed view do.
    var symbol: String? {
        switch self {
        case .terminals: return "terminal"
        case .files: return "folder"
        case .extensions: return "square.grid.2x2"
        case .orchestrator: return "aqi.medium"
        default: return nil
        }
    }

    /// Terminals is the sidebar's reason to exist, so it can't be turned
    /// off; the rest are opt-out.
    var canBeHidden: Bool { self != .terminals }

    var defaultsKey: String? {
        switch self {
        case .terminals: return nil
        case .files: return "SidebarShowFilesPane"
        case .git: return "SidebarShowGitPane"
        case .worktrees: return "SidebarShowWorktreesPane"
        case .extensions: return "SidebarShowExtensionsPane"
        case .orchestrator: return "SidebarShowOrchestratorPane"
        default:
            guard let id = contributedViewID else { return nil }
            return "SidebarShowExtensionView." + id
        }
    }

    var isEnabled: Bool {
        guard let defaultsKey else { return true }
        return UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The built-in panels to actually offer, in tab order.
    static var enabled: [SidebarPane] {
        builtIns.filter(\.isEnabled)
    }
}

/// One entry of the two bars: what it is called, the artwork it wears when
/// it ships one, and what pressing it does.
///
/// The bars used to take `[SidebarPane]` and ask the pane for the name and
/// the icon. A contributed view's name and icon come from a manifest and
/// belong to the extension, not to the pane's identity, so they travel here
/// instead — and so does the descriptor, which is what tells the bar that
/// this entry opens a tab rather than switching the panel under it.
struct SidebarPaneItem: Identifiable, Equatable {
    let pane: SidebarPane
    let title: String

    /// A file the extension shipped, or nil for a built-in.
    ///
    /// **Never an SF Symbol name from a manifest.** A symbol the running
    /// macOS does not resolve makes SwiftUI drop the whole row out of a
    /// `List` with nothing logged — measured, and it cost a debugging
    /// session — so the one thing a third party must not get to choose is a
    /// symbol name. See `ExtensionArtwork`.
    let artwork: URL?

    /// The contributed view this entry draws, or nil for a built-in.
    ///
    /// Only ever a `sidebar` view. An `editor` view has no button: its
    /// `placements` is empty whatever the manifest says, so it never reaches
    /// either bar — see `ExtensionViewContribution.placements(_:surface:)`.
    let descriptor: ExtensionViewDescriptor?

    var id: String { pane.rawValue }

    init(_ pane: SidebarPane) {
        self.pane = pane
        self.title = pane.title
        self.artwork = nil
        self.descriptor = nil
    }

    init(_ descriptor: ExtensionViewDescriptor) {
        self.pane = .view(descriptor.id)
        self.title = descriptor.title
        self.artwork = descriptor.icon
        self.descriptor = descriptor
    }
}

enum SidebarTabBarPlacement: String, CaseIterable, Identifiable {
    case top
    case side

    static let defaultsKey = "SidebarTabBarPlacement"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return "Top"
        case .side: return "Side"
        }
    }

    var menuTitle: String {
        switch self {
        case .top: return "Tabs at the Top"
        case .side: return "Tabs at the Side"
        }
    }

    init(raw: String?) {
        self = raw.flatMap(Self.init(rawValue:)) ?? .top
    }

    static var current: SidebarTabBarPlacement {
        SidebarTabBarPlacement(raw: UserDefaults.standard.string(forKey: defaultsKey))
    }

    /// The placement a manifest names, for this bar.
    ///
    /// The switcher is one list drawn in one of two places, so this is what
    /// `contributes.views[].placements` is checked against: a view whose
    /// button is only in the `topBar` is offered while the bar is at the top
    /// and not while it is at the side, which is what the author asked for.
    var contribution: ExtensionViewContribution.Placement {
        switch self {
        case .top: return .topBar
        case .side: return .sidebar
        }
    }
}

/// A bar entry's icon: an SF Symbol, an asset, or a file an extension
/// shipped.
struct SidebarPaneIcon: View {
    let item: SidebarPaneItem
    var size: CGFloat = 10

    init(item: SidebarPaneItem, size: CGFloat = 10) {
        self.item = item
        self.size = size
    }

    init(pane: SidebarPane, size: CGFloat = 10) {
        self.init(item: SidebarPaneItem(pane), size: size)
    }

    var body: some View {
        if let artwork = item.artwork {
            ExtensionArtwork(url: artwork, size: size + 2)
        } else if let symbol = item.pane.symbol {
            Image(systemName: resolvedSymbol(symbol, for: item.pane))
                .font(.system(size: size, weight: .medium))
        } else if item.pane == .worktrees {
            WorktreeIcon(size: size + 2)
        } else {
            GitIcon(size: size + 1)
        }
    }

    private func resolvedSymbol(_ symbol: String, for pane: SidebarPane) -> String {
        // `aqi.medium` is not present in every SF Symbols version supported
        // by Phantom. Keep the requested mark on newer systems and retain a
        // visible orchestrator mark on older ones instead of rendering an
        // empty Image view.
        if pane == .orchestrator,
           NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil {
            return "arrow.triangle.branch"
        }
        return symbol
    }
}

/// What the two bars offer: the built-in panels the reader kept, then a
/// button per view the installed extensions contribute.
///
/// One object for both because the answer is one list, and because
/// `SidebarPane.isEnabled` reads `UserDefaults` directly — which SwiftUI has
/// no way to observe.
@MainActor
final class SidebarPaneVisibility: ObservableObject {
    static let shared = SidebarPaneVisibility()

    @Published private(set) var items: [SidebarPaneItem]

    private var subscriptions: [AnyCancellable] = []
    private let registry: ExtensionViewRegistry

    init(registry: ExtensionViewRegistry = .shared) {
        self.registry = registry
        items = Self.items(contributing: registry.views(at: SidebarTabBarPlacement.current.contribution))

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.recompute() }
            }
            .store(in: &subscriptions)

        registry.$views
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.recompute() }
            }
            .store(in: &subscriptions)
    }

    /// The entries, as panes. Kept for the callers that only need identity —
    /// the fallback in `SidebarView` and the titlebar chrome.
    var enabled: [SidebarPane] {
        items.map(\.pane)
    }

    /// With only terminals left there is nothing to switch between, so the
    /// tab bar hides itself entirely and the sidebar goes back to being the
    /// plain terminal list it started as.
    ///
    /// Answered here rather than by `SidebarPane`, because the list now
    /// includes what the extensions contribute and this object is the only
    /// one that knows it.
    var showsTabBar: Bool {
        items.count > 1
    }

    func isEnabled(_ pane: SidebarPane) -> Bool {
        enabled.contains(pane)
    }

    func binding(for pane: SidebarPane) -> Binding<Bool> {
        Binding(
            get: { pane.isEnabled },
            set: { value in
                guard let key = pane.defaultsKey else { return }
                UserDefaults.standard.set(value, forKey: key)
            }
        )
    }

    /// The contributed views, whether or not the reader kept their buttons,
    /// so the switcher menu can offer one that is switched off.
    var contributed: [SidebarPaneItem] {
        registry.views(at: SidebarTabBarPlacement.current.contribution).map(SidebarPaneItem.init)
    }

    private func recompute() {
        let next = Self.items(contributing: registry.views(at: SidebarTabBarPlacement.current.contribution))
        guard next != items else { return }
        items = next
    }

    nonisolated static func items(contributing views: [ExtensionViewDescriptor]) -> [SidebarPaneItem] {
        SidebarPane.enabled.map(SidebarPaneItem.init)
            + views.map(SidebarPaneItem.init).filter { $0.pane.isEnabled }
    }
}

struct SidebarPaneSwitcherMenu: View {
    enum Entry: Equatable, Identifiable {
        case placement(SidebarTabBarPlacement)
        case separator
        case pane(SidebarPaneItem, canToggle: Bool)

        var id: String {
            switch self {
            case .placement(let placement): return "placement." + placement.rawValue
            case .separator: return "separator"
            case .pane(let item, _): return "pane." + item.id
            }
        }
    }

    @ObservedObject private var visibility: SidebarPaneVisibility = .shared

    @AppStorage(SidebarTabBarPlacement.defaultsKey)
    private var placementRaw = SidebarTabBarPlacement.top.rawValue

    /// Both placements, then every built-in panel, then the contributed
    /// views behind a separator of their own.
    ///
    /// A contributed view's button is always toggleable: it is somebody
    /// else's page, and the reader gets to take it out of the bar.
    static func entries(contributing contributed: [SidebarPaneItem]) -> [Entry] {
        SidebarTabBarPlacement.allCases.map(Entry.placement)
            + [.separator]
            + SidebarPane.builtIns.map { .pane(SidebarPaneItem($0), canToggle: $0.canBeHidden) }
            + (contributed.isEmpty ? [] : [.separator])
            + contributed.map { .pane($0, canToggle: true) }
    }

    var body: some View {
        ForEach(Self.entries(contributing: visibility.contributed)) { entry in
            item(entry)
        }
    }

    @ViewBuilder
    private func item(_ entry: Entry) -> some View {
        switch entry {
        case .placement(let placement):
            Toggle(placement.menuTitle, isOn: placementBinding(placement))
        case .separator:
            Divider()
        case .pane(let item, let canToggle):
            Toggle(item.title, isOn: visibility.binding(for: item.pane))
                .disabled(!canToggle)
        }
    }

    private func placementBinding(_ placement: SidebarTabBarPlacement) -> Binding<Bool> {
        Binding(
            get: { SidebarTabBarPlacement(raw: placementRaw) == placement },
            set: { isOn in
                guard isOn else { return }
                placementRaw = placement.rawValue
            }
        )
    }
}

extension View {
    func sidebarPaneSwitcherMenu() -> some View {
        contextMenu { SidebarPaneSwitcherMenu() }
    }
}
