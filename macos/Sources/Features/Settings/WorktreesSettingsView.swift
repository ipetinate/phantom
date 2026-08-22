import SwiftUI

/// The Worktrees section: where managed worktrees live, and what a new one
/// runs before anybody types into it.
struct WorktreesSettingsView: View {
    @AppStorage(WorktreeSettings.defaultsKey) private var managedRootRaw = ""

    /// The field edits a working copy and commits on submit, because the
    /// migration offer needs the *previous* root to move things from — a
    /// binding writing on every keystroke destroys the old value before the
    /// question can be asked.
    @State private var rootDraft = ""
    @State private var migration: Migration?

    /// The stores publish nothing, so edits bump this to redraw — the
    /// documented cost of the one-blob-one-key idiom.
    @State private var defaultsRevision = 0

    @State private var addingRepo = false
    @State private var editingRoot: String?

    var body: some View {
        Form {
            Section {
                TextField(
                    "Worktrees Folder",
                    text: $rootDraft,
                    prompt: Text(verbatim: "~/.phantom/worktrees"))
                .autocorrectionDisabled()
                .onSubmit(commitRoot)
            } header: {
                Text("Location")
            } footer: {
                Text("New worktrees are created under this folder, as <repo>/<branch>. Press Return to apply; if the old folder holds managed worktrees, you'll be offered to move them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                let setups = WorktreeSetupStore.all.sorted { $0.key < $1.key }
                if setups.isEmpty {
                    Text("No repository has a setup step yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(setups, id: \.key) { root, setup in
                    Button {
                        editingRoot = root
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((root as NSString).abbreviatingWithTildeInPath)
                                    .font(.system(size: 12, weight: .medium))
                                if !setup.command.isEmpty {
                                    Text(setup.command)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if !setup.copyPaths.isEmpty {
                                    Text(verbatim: "copies: " + setup.copyPaths.joined(separator: ", "))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button("Add Repository…") { addingRepo = true }
            } header: {
                Text("Setup After Creating")
            } footer: {
                Text("Runs once in each new worktree, through your login shell — install dependencies, copy an .env, build. A failed setup keeps the worktree; it only skips the convenience.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .id(defaultsRevision)
        .onAppear { rootDraft = managedRootRaw }
        .alert(item: $migration) { migration in
            Alert(
                title: Text("Move existing worktrees?"),
                message: Text(verbatim: "\(migration.moves.count) managed worktree\(migration.moves.count == 1 ? "" : "s") live under the old folder. Moving runs git worktree move for each, then repair, so nothing loses track of its repository."),
                primaryButton: .default(Text("Move All")) { run(migration) },
                secondaryButton: .default(Text("Leave in Place")) { })
        }
        .fileImporter(
            isPresented: $addingRepo,
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let url) = result else { return }
            let root = GitCommonDir.resolve(from: url.path) ?? url.path
            if WorktreeSetupStore.setup(forMainCheckout: root) == nil {
                WorktreeSetupStore.set(
                    WorktreeSetup(command: " ", copyPaths: []), forMainCheckout: root)
            }
            editingRoot = root
            defaultsRevision += 1
        }
        .sheet(item: Binding(
            get: { editingRoot.map { EditingRoot(root: $0) } },
            set: { editingRoot = $0?.root }
        )) { editing in
            WorktreeSetupEditor(root: editing.root) {
                editingRoot = nil
                defaultsRevision += 1
            }
        }
    }

    private struct EditingRoot: Identifiable {
        let root: String
        var id: String { root }
    }
}

/// Editing one repository's setup.
private struct WorktreeSetupEditor: View {
    let root: String
    let onDone: () -> Void

    @State private var command = ""
    @State private var copyPathsRaw = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text((root as NSString).abbreviatingWithTildeInPath)
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Command").font(.caption).foregroundStyle(.secondary)
                TextField("yarn install", text: $command)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Copy from the main checkout (one path per line)")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $copyPathsRaw)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 70)
                    .autocorrectionDisabled()
            }

            HStack {
                Button("Remove Setup", role: .destructive) {
                    WorktreeSetupStore.set(WorktreeSetup(), forMainCheckout: root)
                    onDone()
                }
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Save") {
                    let paths = copyPathsRaw
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    WorktreeSetupStore.set(
                        WorktreeSetup(command: command.trimmingCharacters(in: .whitespaces),
                                      copyPaths: paths),
                        forMainCheckout: root)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear {
            let setup = WorktreeSetupStore.setup(forMainCheckout: root) ?? WorktreeSetup()
            command = setup.command.trimmingCharacters(in: .whitespaces)
            copyPathsRaw = setup.copyPaths.joined(separator: "\n")
        }
    }
}

extension WorktreesSettingsView {
    /// One planned relocation: a worktree, where it is, where it goes, and
    /// which repository owns it.
    struct Migration: Identifiable {
        let id = UUID()
        let moves: [(from: String, to: String, commonRoot: String)]
    }

    private func commitRoot() {
        let oldRoot = WorktreeSettings.managedRoot
        managedRootRaw = rootDraft
        let newRoot = WorktreeSettings.managedRoot
        guard oldRoot != newRoot else { return }

        let moves = Self.plannedMoves(from: oldRoot, to: newRoot)
        if !moves.isEmpty { migration = Migration(moves: moves) }
    }

    /// Everything under the old root that answers to a repository, mapped to
    /// the same relative position under the new one. Two levels deep, the
    /// shape the derivation writes: `<root>/<repo>/<branch>`.
    static func plannedMoves(
        from oldRoot: String,
        to newRoot: String,
        fileManager: FileManager = .default
    ) -> [(from: String, to: String, commonRoot: String)] {
        var moves: [(from: String, to: String, commonRoot: String)] = []
        let repos = (try? fileManager.contentsOfDirectory(atPath: oldRoot)) ?? []
        for repo in repos where !repo.hasPrefix(".") {
            let repoDir = (oldRoot as NSString).appendingPathComponent(repo)
            let branches = (try? fileManager.contentsOfDirectory(atPath: repoDir)) ?? []
            for branch in branches where !branch.hasPrefix(".") {
                let path = (repoDir as NSString).appendingPathComponent(branch)
                guard let commonRoot = GitCommonDir.resolve(from: path),
                      commonRoot != path
                else { continue }
                let target = ((newRoot as NSString)
                    .appendingPathComponent(repo) as NSString)
                    .appendingPathComponent(branch)
                moves.append((from: path, to: target, commonRoot: commonRoot))
            }
        }
        return moves
    }

    /// Sequential on purpose: two mutations on one repository would trip the
    /// center's busy lock, and a failure mid-list must not stop the rest —
    /// each move is independent, and the ones that fail surface through the
    /// center's own failure sheet.
    private func run(_ migration: Migration, index: Int = 0) {
        guard index < migration.moves.count else { return }
        let move = migration.moves[index]
        try? FileManager.default.createDirectory(
            atPath: (move.to as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        WorktreeCenter.shared.move(
            path: move.from, to: move.to, commonRoot: move.commonRoot
        ) { _ in
            run(migration, index: index + 1)
        }
    }
}
