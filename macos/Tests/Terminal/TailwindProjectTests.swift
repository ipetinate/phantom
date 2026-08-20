import Foundation
@testable import Ghostty
import Testing

/// Whether a file's project has Tailwind, and what that adds to the servers
/// it gets.
struct TailwindProjectTests {
    private func inTemporaryTree(
        _ directories: [String],
        _ body: (String) throws -> Void
    ) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tailwind-\(UUID().uuidString)")

        for directory in directories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        try body(root.path)
    }

    @Test func findsItBesideTheFile() throws {
        try inTemporaryTree(["src", "node_modules/tailwindcss"]) { root in
            let resolved = TailwindProject.resolve(forPath: root + "/src/App.tsx", root: root)
            #expect(resolved.isInstalled)
        }
    }

    /// The reason this walks up where `TypeScriptToolchain.resolve` does not:
    /// a monorepo hoists `node_modules` to the repository root, and stopping
    /// at the file's own package would turn the feature off in exactly the
    /// repositories most likely to use it.
    @Test func findsItHoistedAtTheRepositoryRoot() throws {
        try inTemporaryTree(["apps/web/src", "node_modules/tailwindcss"]) { root in
            let resolved = TailwindProject.resolve(forPath: root + "/apps/web/src/App.tsx", root: root)
            #expect(resolved.isInstalled)
        }
    }

    @Test func findsThePackagesOwnCopyFirst() throws {
        try inTemporaryTree(["apps/web/node_modules/tailwindcss", "node_modules/tailwindcss"]) { root in
            let resolved = TailwindProject.resolve(forPath: root + "/apps/web/App.tsx", root: root)
            #expect(resolved == .installed(at: root + "/apps/web/node_modules/tailwindcss"))
        }
    }

    @Test func absentWhenTheProjectHasNoTailwind() throws {
        try inTemporaryTree(["src", "node_modules/react"]) { root in
            #expect(TailwindProject.resolve(forPath: root + "/src/App.tsx", root: root) == .absent)
        }
    }

    /// The walk stops at the workspace root rather than climbing out of it.
    /// Somebody with Tailwind installed in their home directory does not have
    /// a Tailwind project in every repository below it.
    @Test func doesNotClimbAboveTheWorkspaceRoot() throws {
        try inTemporaryTree(["repo/src", "node_modules/tailwindcss"]) { root in
            let resolved = TailwindProject.resolve(
                forPath: root + "/repo/src/App.tsx",
                root: root + "/repo"
            )
            #expect(resolved == .absent)
        }
    }

    @Test func aFileAtTheRootIsLookedAtOnce() throws {
        try inTemporaryTree(["node_modules/tailwindcss"]) { root in
            #expect(TailwindProject.resolve(forPath: root + "/App.tsx", root: root).isInstalled)
        }
    }

    // MARK: - What it adds to the routing

    @Test func addsTheServerLastForAReactFile() {
        let servers = LSPServerRegistry.servers(
            forPath: "/w/App.tsx",
            toolchain: .native,
            tailwind: .installed(at: "/w/node_modules/tailwindcss")
        )
        #expect(servers.count == 2)
        #expect(servers.last?.command == LSPServerRegistry.tailwindCommand)
        #expect(servers.last?.languageID == "typescriptreact")
    }

    /// A `.vue` already gets two, and Tailwind is the third — the primary
    /// pair keeps its order.
    @Test func joinsTheVuePairWithoutDisturbingIt() {
        let servers = LSPServerRegistry.servers(
            forPath: "/w/App.vue",
            toolchain: .native,
            tailwind: .installed(at: "/w/node_modules/tailwindcss")
        )
        #expect(servers.map(\.command) == [
            "vue-language-server",
            "typescript-language-server",
            LSPServerRegistry.tailwindCommand,
        ])
    }

    @Test func routesNothingExtraWithoutTailwind() {
        let servers = LSPServerRegistry.servers(forPath: "/w/App.tsx", toolchain: .native, tailwind: .absent)
        #expect(!servers.contains { $0.command == LSPServerRegistry.tailwindCommand })
    }

    /// JSX is a syntax error in a `.ts`, so a `class=` attribute cannot appear
    /// in one and a second process for it would answer nothing. `.js` is the
    /// other way round — JSX in a `.js` is what half of npm ships.
    @Test func languagesThatCannotHoldAClassAttribute() {
        let installed = TailwindProject.installed(at: "/w/node_modules/tailwindcss")

        let typescript = LSPServerRegistry.servers(forPath: "/w/util.ts", toolchain: .native, tailwind: installed)
        #expect(!typescript.contains { $0.command == LSPServerRegistry.tailwindCommand })

        let javascript = LSPServerRegistry.servers(forPath: "/w/util.js", toolchain: .native, tailwind: installed)
        #expect(javascript.contains { $0.command == LSPServerRegistry.tailwindCommand })
    }

    /// One row in Settings, not five — the list dedups by binary and all five
    /// language ids share one.
    @Test func settingsListsOneRow() {
        let rows = LSPServerRegistry.distinctServers
            .filter { $0.command == LSPServerRegistry.tailwindCommand }
        #expect(rows.count == 1)
    }

    /// It lists with CSS, not with the script servers whose language ids it
    /// shares. The `category` switch has a `default` that answers `.script`,
    /// so a server nobody classified lands in the wrong section quietly.
    @Test func listsUnderStyles() {
        let tailwind = LSPServerRegistry.tailwindServer(forLanguage: "typescriptreact")
        #expect(tailwind?.category == .styles)
        #expect(LSPServerRegistry.tailwindServers.allSatisfy { $0.category == .styles })
    }

    /// `byLanguageID` must still answer with the server that completes the
    /// language itself. Tailwind repeats ids that `all` already has, which is
    /// why it is a table of its own.
    @Test func doesNotBecomeTheLanguagesOwnServer() {
        #expect(LSPServerRegistry.server(forLanguage: "typescriptreact")?.command != LSPServerRegistry.tailwindCommand)
        #expect(LSPServerRegistry.server(forLanguage: "html")?.command != LSPServerRegistry.tailwindCommand)
        #expect(LSPServerRegistry.server(forLanguage: "vue")?.command != LSPServerRegistry.tailwindCommand)
    }
}
