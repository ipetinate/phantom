import Combine
import Foundation

/// What the reader has granted, and what is waiting to be asked.
///
/// Grants marked "always" outlive the app; the ones granted for a single call
/// do not, and are never written down. That split is the whole persistence
/// rule: a permission the reader gave once, in a hurry, must not be waiting
/// for them tomorrow.
@MainActor
final class MCPPermissionStore: ObservableObject {
    static let shared = MCPPermissionStore()

    /// Everything granted for good, as the settings pane lists it.
    @Published private(set) var grants: [MCPPermission.Grant] = []

    /// The question on screen, if any. One at a time: two sheets stacked over
    /// each other is how a reader answers the one they did not read.
    @Published var pending: Pending?

    struct Pending: Identifiable {
        let id = UUID()
        var request: MCPPermission.Request
        var client: String?
        var tabTitle: String?

        /// What exactly is being asked for, when the capability alone does not
        /// say it. A request to change a setting has to name the setting and
        /// show the value: approving a change you cannot see is a signature on
        /// a blank page, and it is the reason this field exists.
        var detail: String?

        /// Called with what the reader chose, or nil when they refused.
        var answer: (MCPPermission.Scope?, _ always: Bool) -> Void
    }

    /// Granted for this call only. Kept apart from `grants` so nothing
    /// transient can reach the defaults, and cleared when the client goes.
    private var once: [ObjectIdentifier: [MCPPermission.Grant]] = [:]

    /// When each tab was last refused, so an agent that asks in a loop is
    /// turned away without a sheet.
    ///
    /// A prompt that appears ten times is a prompt that gets accepted without
    /// being read, which is the failure mode this whole design exists to
    /// avoid — so the protection has to be against the *asking*, not against
    /// the reader.
    private var refusedAt: [UUID: Date] = [:]

    static let cooldown: TimeInterval = 60

    private let defaults: UserDefaults
    private static let key = "MCPGrants"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        grants = Self.load(from: defaults)
    }

    // MARK: Asking

    /// Whether a client may do this, asking the reader when it is not already
    /// settled.
    ///
    /// - Parameter client: an object identity for the connection, so a grant
    ///   given "once" belongs to it and dies with it.
    func decide(
        _ request: MCPPermission.Request,
        client: ObjectIdentifier,
        clientName: String?,
        tabTitle: String?,
        detail: String? = nil,
        then answer: @escaping (Bool) -> Void
    ) {
        let held = grants + (once[client] ?? [])
        if MCPPermission.isAllowed(request, by: held) { return answer(true) }

        if let surface = request.surface, let last = refusedAt[surface],
           Date().timeIntervalSince(last) < Self.cooldown {
            return answer(false)
        }

        /// One question at a time. A second while the first is on screen is
        /// refused rather than queued: an agent that fires three calls at once
        /// would otherwise put three sheets in front of the reader.
        guard pending == nil else { return answer(false) }

        pending = Pending(
            request: request,
            client: clientName,
            tabTitle: tabTitle,
            detail: detail
        ) { [weak self] scope, always in
            guard let self else { return answer(false) }
            self.pending = nil

            guard let scope else {
                if let surface = request.surface { self.refusedAt[surface] = Date() }
                return answer(false)
            }

            let grant = MCPPermission.Grant(
                capability: request.capability,
                scope: scope,
                surface: request.surface,
                group: request.group)

            if always {
                self.grants.append(grant)
                self.save()
            } else {
                self.once[client, default: []].append(grant)
            }

            answer(true)
        }
    }

    /// Drops what a connection was given for the length of one call.
    func forget(client: ObjectIdentifier) {
        once.removeValue(forKey: client)
    }

    // MARK: Revoking

    func revoke(_ grant: MCPPermission.Grant) {
        grants.removeAll { $0 == grant }
        save()
    }

    func revokeAll() {
        grants.removeAll()
        save()
    }

    // MARK: Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(grants) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func load(from defaults: UserDefaults) -> [MCPPermission.Grant] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MCPPermission.Grant].self, from: data)) ?? []
    }
}
