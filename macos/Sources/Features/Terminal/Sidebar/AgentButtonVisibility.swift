import Foundation

@MainActor
final class AgentButtonVisibility: ObservableObject {
    static let shared = AgentButtonVisibility()

    @Published private(set) var shown: [AgentButtonSurface: [CodingAgent]]

    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.shown = Self.read { defaults.object(forKey: $0) as? Bool }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func agents(on surface: AgentButtonSurface) -> [CodingAgent] {
        shown[surface] ?? []
    }

    func reload() {
        let now = Self.read { defaults.object(forKey: $0) as? Bool }
        if now != shown { shown = now }
    }

    nonisolated static func read(_ stored: (String) -> Bool?) -> [AgentButtonSurface: [CodingAgent]] {
        var result: [AgentButtonSurface: [CodingAgent]] = [:]
        for surface in AgentButtonSurface.allCases {
            result[surface] = CodingAgent.allCases.filter {
                AgentButtonDefaults.isShown(surface, $0, stored: stored)
            }
        }
        return result
    }
}
