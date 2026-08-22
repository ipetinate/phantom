import Foundation

/// What to do to a freshly created worktree before anyone types into it.
///
/// Per repository, keyed by the main checkout's path — the one identity every
/// worktree of a repo shares. A worktree is born without everything the repo
/// gitignores: dependencies, env files, build artifacts. Without a setup step
/// the first experience of every new worktree is "created, and doesn't run".
struct WorktreeSetup: Codable, Equatable {
    /// Run in the new worktree through the login shell, the way the language
    /// server installs run. Typed by the user in Settings — the same trust as
    /// typing it into the terminal — and never read from a file in the repo,
    /// which is the boundary the rest of the app's command execution keeps.
    var command: String = ""

    /// Gitignored paths, relative to the main checkout, to copy into the new
    /// worktree before the command runs — an `.env` the install cannot
    /// produce, a prebuilt artifact too slow to rebuild.
    var copyPaths: [String] = []

    var isEmpty: Bool {
        command.trimmingCharacters(in: .whitespaces).isEmpty && copyPaths.isEmpty
    }
}

/// One blob under one key, the `LSPServerOverrideStore` idiom: an absent
/// entry means "nothing to do", so a repo never configured costs nothing to
/// look up and nothing to store.
///
/// Same caveat as the sibling stores: `UserDefaults` publishes nothing, so a
/// Settings view editing this needs its own revision bump to redraw.
enum WorktreeSetupStore {
    static let defaultsKey = "WorktreeSetups"

    static var all: [String: WorktreeSetup] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: WorktreeSetup].self, from: data)
        else { return [:] }
        return decoded
    }

    static func setup(forMainCheckout root: String) -> WorktreeSetup? {
        all[root]
    }

    static func set(_ setup: WorktreeSetup, forMainCheckout root: String) {
        var current = all
        if setup.isEmpty {
            current.removeValue(forKey: root)
        } else {
            current[root] = setup
        }
        guard let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
