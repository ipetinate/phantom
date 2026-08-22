import Foundation
@testable import Ghostty
import Testing

/// The per-repository setup blob: one key, one dictionary, absent means
/// nothing to do.
///
/// Serialized and snapshot-wrapped for the same reason `SidebarPaneTests`
/// is: the store reads the real defaults, and a test must not leave a setup
/// command behind on the machine it ran on.
@Suite(.serialized)
struct WorktreeSetupStoreTests {
    private func withCleanStore(_ body: () -> Void) {
        let saved = UserDefaults.standard.object(forKey: WorktreeSetupStore.defaultsKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: WorktreeSetupStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: WorktreeSetupStore.defaultsKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: WorktreeSetupStore.defaultsKey)
        body()
    }

    @Test func aSetupRoundTrips() {
        withCleanStore {
            let setup = WorktreeSetup(command: "yarn install", copyPaths: [".env", "dist"])
            WorktreeSetupStore.set(setup, forMainCheckout: "/repo")

            #expect(WorktreeSetupStore.setup(forMainCheckout: "/repo") == setup)
        }
    }

    @Test func anUnconfiguredRepoAnswersNil() {
        withCleanStore {
            #expect(WorktreeSetupStore.setup(forMainCheckout: "/never") == nil)
        }
    }

    /// Writing an empty setup is how removal is spelled, so a cleared form
    /// leaves no entry behind rather than an entry that does nothing.
    @Test func anEmptySetupRemovesTheEntry() {
        withCleanStore {
            WorktreeSetupStore.set(
                WorktreeSetup(command: "make", copyPaths: []), forMainCheckout: "/repo")
            WorktreeSetupStore.set(WorktreeSetup(), forMainCheckout: "/repo")

            #expect(WorktreeSetupStore.setup(forMainCheckout: "/repo") == nil)
            #expect(WorktreeSetupStore.all.isEmpty)
        }
    }

    /// Whitespace is not a command. The Settings flow stores a placeholder
    /// space while the editor sheet opens, and that must count as empty.
    @Test func aWhitespaceCommandWithNoPathsIsEmpty() {
        #expect(WorktreeSetup(command: "  ", copyPaths: []).isEmpty)
        #expect(!WorktreeSetup(command: "", copyPaths: [".env"]).isEmpty)
    }

    @Test func reposDoNotShareSetups() {
        withCleanStore {
            WorktreeSetupStore.set(
                WorktreeSetup(command: "a", copyPaths: []), forMainCheckout: "/one")
            WorktreeSetupStore.set(
                WorktreeSetup(command: "b", copyPaths: []), forMainCheckout: "/two")

            #expect(WorktreeSetupStore.setup(forMainCheckout: "/one")?.command == "a")
            #expect(WorktreeSetupStore.setup(forMainCheckout: "/two")?.command == "b")
        }
    }
}
