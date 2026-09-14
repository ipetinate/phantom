import AppKit
import Combine
import Foundation

@MainActor
final class AgentOverviewCenter: ObservableObject {
    static let shared = AgentOverviewCenter()

    static let pidInterval: TimeInterval = 2
    static let previewInterval: TimeInterval = 1
    static let previewLineCount = 6

    @Published private(set) var cards: [AgentSessionCard] = []
    @Published var query: String = ""
    @Published var stateFilter: Set<AgentTabState> = []
    @Published var includeOrphans = false

    private var cancellables: Set<AnyCancellable> = []
    private var pidTimer: Timer?
    private var previewTimer: Timer?
    private var pendingRebuild = false
    private var openCount = 0

    private var foregroundNames: [UUID: String] = [:]
    private var idle: [UUID: Bool] = [:]
    private var previews: [UUID: [String]] = [:]
    private var visible: Set<UUID> = []

    var filtered: [AgentSessionCard] {
        AgentSessionFilter.apply(cards, query: query, states: stateFilter)
    }

    private init() {
        let center = TabStateCenter.shared
        center.$records.sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &cancellables)
        center.$states.sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &cancellables)
        center.$updatedAt.sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &cancellables)

        let groups = SidebarGroupStore.shared
        groups.$groups.sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &cancellables)
        groups.$assignments.sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &cancellables)

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.scheduleRebuild() }
                .store(in: &cancellables)
        }
    }

    func beginObserving() {
        openCount += 1
        guard openCount == 1 else { return }
        sampleProcesses()
        samplePreviews()
        rebuild()

        pidTimer = Timer.scheduledTimer(withTimeInterval: Self.pidInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.sampleProcesses()
                self?.scheduleRebuild()
            }
        }
        previewTimer = Timer.scheduledTimer(withTimeInterval: Self.previewInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.samplePreviews()
                self?.scheduleRebuild()
            }
        }
    }

    func endObserving() {
        openCount = max(0, openCount - 1)
        guard openCount == 0 else { return }
        pidTimer?.invalidate()
        pidTimer = nil
        previewTimer?.invalidate()
        previewTimer = nil
        previews.removeAll()
        visible.removeAll()
    }

    func noteVisible(_ ids: Set<UUID>) {
        guard ids != visible else { return }
        visible = ids
        samplePreviews()
        scheduleRebuild()
    }

    func refreshPreview(for id: UUID) {
        guard let surface = Self.surface(for: id) else { return }
        previews[id] = Self.previewLines(of: surface)
        scheduleRebuild()
    }

    private func scheduleRebuild() {
        guard !pendingRebuild else { return }
        pendingRebuild = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingRebuild = false
            rebuild()
        }
    }

    private func rebuild() {
        let center = TabStateCenter.shared
        let composed = AgentSessionComposer.compose(.init(
            records: center.records,
            states: center.states,
            updatedAt: center.updatedAt,
            surfaces: Self.surfaceFacts(),
            foregroundNames: foregroundNames,
            idle: idle,
            previews: previews,
            includeOrphans: includeOrphans))
        if composed != cards { cards = composed }
    }

    private func sampleProcesses() {
        let known = Set(TabStateCenter.shared.records.keys)
        var names: [UUID: String] = [:]
        var busy: [UUID: Bool] = [:]
        for (id, surface) in Self.surfaces() where known.contains(id) {
            guard let pid = surface.surfaceModel?.foregroundPID else { continue }
            busy[id] = TerminalIdleCheck.isIdle(foregroundPID: pid)
            if let name = TerminalIdleCheck.processName(pid) { names[id] = name }
        }
        foregroundNames = names
        idle = busy
    }

    private func samplePreviews() {
        guard !visible.isEmpty else { return }
        var found: [UUID: [String]] = previews
        for (id, surface) in Self.surfaces() where visible.contains(id) {
            found[id] = Self.previewLines(of: surface)
        }
        previews = found
    }

    private static func previewLines(of surface: Ghostty.SurfaceView) -> [String] {
        let text = surface.cachedVisibleContents.get()
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .reversed()
            .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(AgentOverviewCenter.previewLineCount)
            .reversed()
            .map { $0 }
    }

    static func surfaces() -> [(UUID, Ghostty.SurfaceView)] {
        var found: [(UUID, Ghostty.SurfaceView)] = []
        var seen: Set<UUID> = []
        for controller in TerminalController.all {
            guard let tree = controller.surfaceTree.root else { continue }
            for surface in tree.leaves() where seen.insert(surface.id).inserted {
                found.append((surface.id, surface))
            }
        }
        return found
    }

    static func surface(for id: UUID) -> Ghostty.SurfaceView? {
        surfaces().first { $0.0 == id }?.1
    }

    static func controller(for id: UUID) -> (TerminalController, Ghostty.SurfaceView)? {
        for controller in TerminalController.all {
            guard let tree = controller.surfaceTree.root else { continue }
            if let surface = tree.leaves().first(where: { $0.id == id }) {
                return (controller, surface)
            }
        }
        return nil
    }

    private static func surfaceFacts() -> [AgentSessionSurfaceFacts] {
        let store = SidebarGroupStore.shared
        var found: [AgentSessionSurfaceFacts] = []
        var seen: Set<UUID> = []

        for controller in TerminalController.all {
            guard let tree = controller.surfaceTree.root else { continue }
            let focused = controller.focusedSurface?.id
            for surface in tree.leaves() where seen.insert(surface.id).inserted {
                let title = controller.titleOverride
                    ?? (surface.title.isEmpty ? nil : surface.title)
                    ?? controller.window?.title
                    ?? "Terminal"
                let group = store.resolveGroup(surfaceId: surface.id, pwd: surface.pwd)
                found.append(AgentSessionSurfaceFacts(
                    id: surface.id,
                    title: title,
                    pwd: surface.pwd,
                    groupID: group?.id,
                    groupName: group?.name,
                    worktreeBranch: nil,
                    isFocused: surface.id == focused && controller.window?.isKeyWindow == true))
            }
        }
        return found
    }
}
