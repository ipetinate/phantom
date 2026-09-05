import Foundation

struct InstalledExtension: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    let root: URL
}

enum ExtensionState: Equatable, Sendable {
    case notInstalled
    case installed(version: String)
    case updateAvailable(installed: String, available: String)
}

enum ExtensionActivity: Equatable, Sendable {
    case downloading(fraction: Double?)
    case verifying
    case installing
    case removing
}

@MainActor
final class ExtensionStore: ObservableObject {
    static let shared = ExtensionStore()

    static let indexURL = URL(
        string: "https://github.com/ipetinate/phantom-extensions/releases/download/index/index.json"
    )!

    @Published private(set) var index: ExtensionIndex?
    @Published private(set) var installed: [InstalledExtension] = []
    @Published private(set) var activity: [String: ExtensionActivity] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshError: String?

    func refresh() async {}

    func reloadInstalled() {}

    func install(_ entry: ExtensionIndex.Entry) async {}

    func remove(id: String) async {}

    func state(for entry: ExtensionIndex.Entry) -> ExtensionState {
        .notInstalled
    }
}
