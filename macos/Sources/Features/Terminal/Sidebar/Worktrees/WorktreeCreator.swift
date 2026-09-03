import SwiftUI

/// The sheet that creates a worktree: which branch, where it lands, and what
/// happens to it before anyone types.
///
/// The path is derived and read-only — the managed root exists precisely so
/// nobody has to choose a directory, and an editable field would reopen every
/// lost-worktree story the root closes. Fetch is a button, never automatic:
/// network git in this app is user-initiated only.
struct WorktreeCreator: View {
    let commonRoot: String

    /// A base to arrive with — the "new worktree from this one" gesture. The
    /// sheet is the same either way; only the starting selection changes.
    var initialBase: String?
    let onDone: () -> Void
    let onOpenTerminal: (String) -> Void

    @ObservedObject private var center: WorktreeCenter = .shared
    @ObservedObject private var git: GitCenter = .shared
    @ObservedObject private var palette: ThemePalette = .shared

    private enum Mode: String, CaseIterable, Identifiable {
        case newBranch = "New branch"
        case existing = "Existing branch"
        var id: String { rawValue }
    }

    private enum Phase {
        case configuring
        case creating
        case settingUp(log: [String])
    }

    @State private var mode: Mode = .newBranch
    @State private var branchName = ""
    @State private var base = ""
    @State private var existingBranch = ""
    @State private var isChoosingBase = false
    @State private var isChoosingExisting = false
    @State private var opensTerminal = true
    @State private var phase: Phase = .configuring
    @State private var setupTask: Task<Void, Never>?

    /// A failure shown *inside* the sheet. The panel's own failure sheet
    /// cannot present while this one is up — SwiftUI shows one sheet per
    /// presenter — so a create error surfaced there only after Cancel, which
    /// read as "Create did nothing, then complained later".
    @State private var failure: GitFailure?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Worktree")
                .font(.headline)

            switch phase {
            case .configuring, .creating:
                configuration
            case .settingUp(let log):
                setupProgress(log)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear {
            /// Nobody else loads the branch list — the panel only polls
            /// status — so the picker would sit empty without this ask.
            git.requestBranches(root: commonRoot)
            center.requestMerged(commonRoot: commonRoot)
            adoptDefaults()
            WindowBreadcrumbs.note(
                "worktree-creator: open root=\(commonRoot) " +
                "branches=\(git.branches[commonRoot]?.count ?? -1) " +
                "resolvedBase=\(center.baseRefs[commonRoot] ?? "nil") " +
                "initial=\(initialBase ?? "nil")")
        }
        .onChange(of: git.branches[commonRoot]) { _ in adoptDefaults() }
        .onChange(of: center.baseRefs[commonRoot]) { _ in adoptDefaults() }
    }

    /// A branch, chosen the way branches are chosen everywhere else in the
    /// app: a popover with a field in it.
    ///
    /// These two were `Picker`s, which on macOS is a pop-up menu — so a
    /// repository with three hundred branches gave the reader a menu three
    /// hundred items long and no way to say which one they meant. The label
    /// stays in front so the row still reads as a form field.
    private func branchField(
        label: String,
        value: String,
        branches: [String],
        isPresented: Binding<Bool>,
        onPick: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(palette.font(size: 11))
                .foregroundStyle(.secondary)

            Button {
                isPresented.wrappedValue = true
            } label: {
                HStack(spacing: 4) {
                    Text(value.isEmpty ? "Choose\u{2026}" : value)
                        .font(palette.font(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .popover(isPresented: isPresented, arrowEdge: .bottom) {
                BranchPicker(
                    branches: branches,
                    current: value.isEmpty ? nil : value,
                    onPick: onPick,
                    isPresented: isPresented
                )
            }
        }
    }

    // MARK: Configuration

    @ViewBuilder
    private var configuration: some View {
        Picker("", selection: $mode) {
            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        if baseCandidates.isEmpty && mode == .newBranch {
            /// A repository with no commits has no ref to branch from — the
            /// honest answer is a sentence, not a picker full of guesses.
            StatusCallout(
                kind: .warning,
                title: "Commit first",
                message: "This repository has no commits yet, so no branch exists to base a worktree on. Make the first commit — git add -A && git commit — then come back and this list fills itself.")
        }

        if mode == .newBranch {
            TextField("Branch name", text: $branchName)
                .autocorrectionDisabled()

            HStack(spacing: 8) {
                branchField(
                    label: "From",
                    value: baseSelection.wrappedValue,
                    branches: baseCandidates,
                    isPresented: $isChoosingBase,
                    onPick: { baseSelection.wrappedValue = $0 }
                )
                .disabled(baseCandidates.isEmpty)

                if hasRemoteBase {
                    Button {
                        git.fetch(in: commonRoot)
                    } label: {
                        if git.busy[commonRoot] != nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Fetch origin first")
                        }
                    }
                    .disabled(git.busy[commonRoot] != nil)
                    .help("Updates the base before branching, so the worktree does not start life behind")
                }
            }
        } else {
            branchField(
                label: "Branch",
                value: existingBranch,
                branches: availableBranches,
                isPresented: $isChoosingExisting,
                onPick: { existingBranch = $0 }
            )
            .disabled(availableBranches.isEmpty)

            if availableBranches.isEmpty {
                /// Git allows one worktree per branch, full stop — the same
                /// ref cannot be checked out twice, which is the whole point
                /// of the restriction. So the honest options are: branch
                /// afresh, or free a branch by removing the worktree holding
                /// it. The button switches modes rather than explaining how.
                StatusCallout(
                    kind: .warning,
                    title: "Every branch is already checked out",
                    message: "Git allows one worktree per branch, so none of \(branchTotal == 1 ? "the" : "these \(branchTotal)") local branch\(branchTotal == 1 ? "" : "es") can be added again. Create a new branch instead, or remove the worktree holding the one you want.")

                Button("Create a new branch instead") {
                    mode = .newBranch
                }
                .font(.system(size: 11))
            }
        }

        LabeledContent("Path") {
            Text((derivedPath as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }

        if occupied {
            /// No dismiss: this restates the current input and clears itself
            /// the moment the branch name changes.
            StatusCallout(
                kind: .warning,
                title: "That folder already exists and is not empty",
                message: derivedPath)
        }

        if let failure {
            /// Dismiss clears the moment, not the cause: the failure stays
            /// readable until the reader is done with it, and the X only
            /// resets this one attempt's state.
            StatusCallout(
                kind: .error,
                title: failure.title,
                message: [failure.summary, failure.raw]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n"),
                onDismiss: { self.failure = nil })
        }

        Toggle("Open a new terminal in the worktree", isOn: $opensTerminal)

        HStack {
            Spacer()
            Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
            Button(creating ? "Creating…" : "Create", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate || creating)
        }
    }

    // MARK: Setup phase

    private func setupProgress(_ log: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Setting up…").font(.system(size: 12, weight: .medium))
            }
            /// The rolling tail, the language-server install treatment: enough
            /// to see it moving, never a full console.
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(log.suffix(12).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("Skip") {
                    setupTask?.cancel()
                    finish(opening: createdPath)
                }
            }
        }
    }

    // MARK: Derivations

    @State private var createdPath: String?

    private var creating: Bool {
        if case .creating = phase { return true }
        return false
    }

    private var branch: String {
        mode == .newBranch ? branchName : existingBranch
    }

    private var derivedPath: String {
        guard !branch.trimmingCharacters(in: .whitespaces).isEmpty else {
            return WorktreeSettings.managedRoot
        }
        return WorktreePath.derive(
            managedRoot: WorktreeSettings.managedRoot,
            mainCheckout: commonRoot,
            branch: branch)
    }

    /// Whether the folder this would land in is already taken.
    ///
    /// Only while configuring, and that guard is the whole point: this asks
    /// the filesystem, and the moment git checks the worktree out the folder
    /// exists and is not empty — so during `.creating` it fires about the
    /// folder the flow itself just made, with the button reading "Creating…".
    /// It is a pre-flight check, and it has nothing to say once the work has
    /// started.
    private var occupied: Bool {
        guard case .configuring = phase else { return false }
        return !branch.isEmpty && WorktreePath.isOccupied(derivedPath)
    }

    private var canCreate: Bool {
        guard !branch.trimmingCharacters(in: .whitespaces).isEmpty, !occupied else { return false }
        if mode == .newBranch { return effectiveBase != nil }
        return true
    }

    private var baseCandidates: [String] {
        WorktreeBases.candidates(
            initialBase: initialBase,
            resolvedBase: center.baseRefs[commonRoot],
            localBranches: git.branches[commonRoot] ?? [])
    }

    private var hasRemoteBase: Bool {
        WorktreeBases.hasRemote(resolvedBase: center.baseRefs[commonRoot])
    }

    /// The selection heals itself in the binding rather than in events.
    ///
    /// The branch list arrives whenever git answers, and a Picker whose
    /// stored selection is not among its tags renders blank — which read as
    /// "won't let me choose". Deciding the effective value at read time
    /// removes every ordering question: the moment candidates exist, the
    /// picker shows one, whatever the stored state missed.
    private var baseSelection: Binding<String> {
        Binding(
            get: { effectiveBase ?? "" },
            set: { base = $0 })
    }

    /// What Create actually uses: the stored choice when it is real, else
    /// the first real candidate.
    private var effectiveBase: String? {
        if baseCandidates.contains(base) { return base }
        return baseCandidates.first
    }

    /// The pickers adopt the first real answer to arrive, and never a guess.
    private func adoptDefaults() {
        if base.isEmpty || !baseCandidates.contains(base) {
            base = baseCandidates.first ?? ""
        }
        if existingBranch.isEmpty { existingBranch = availableBranches.first ?? "" }
    }

    /// Local branches not already checked out — git would refuse those, and a
    /// picker should not offer what cannot be picked.
    private var branchTotal: Int {
        (git.branches[commonRoot] ?? []).count
    }

    private var availableBranches: [String] {
        let checkedOut = Set((center.worktrees[commonRoot] ?? []).compactMap(\.branch))
        return (git.branches[commonRoot] ?? []).filter { !checkedOut.contains($0) }
    }

    // MARK: Actions

    private func create() {
        phase = .creating
        failure = nil
        let path = derivedPath
        let completion: @MainActor (Bool) -> Void = { succeeded in
            guard succeeded else {
                /// The failure moves in here and out of the center, so the
                /// panel's sheet does not replay it after this one closes.
                failure = center.lastError?.failure
                center.lastError = nil
                phase = .configuring
                return
            }
            createdPath = path
            runSetup(at: path)
        }

        if mode == .newBranch {
            guard let effectiveBase else {
                phase = .configuring
                return
            }
            center.add(
                path: path, newBranch: branchName, from: effectiveBase,
                commonRoot: commonRoot, completion: completion)
        } else {
            center.add(
                path: path, branch: existingBranch,
                commonRoot: commonRoot, completion: completion)
        }
    }

    /// Copy-paths, then the setup command, then done. A failed setup keeps
    /// the worktree — creation succeeded; only the convenience is being
    /// skipped — so nothing here rolls anything back.
    private func runSetup(at path: String) {
        let setup = WorktreeSetupStore.setup(forMainCheckout: commonRoot)
        guard let setup, !setup.isEmpty else {
            finish(opening: path)
            return
        }

        phase = .settingUp(log: [])
        let mainCheckout = commonRoot
        setupTask = Task.detached(priority: .userInitiated) {
            for relative in setup.copyPaths {
                let source = (mainCheckout as NSString).appendingPathComponent(relative)
                let target = (path as NSString).appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: source) else { continue }
                try? FileManager.default.createDirectory(
                    atPath: (target as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
                try? FileManager.default.copyItem(atPath: source, toPath: target)
            }

            let command = setup.command.trimmingCharacters(in: .whitespaces)
            if !command.isEmpty {
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                _ = ShellCommand.runStreaming(
                    shell,
                    ["-lic", command],
                    cwd: path,
                    environment: LoginEnvironment.executableEnvironment(),
                    timeout: 300
                ) { line in
                    Task { @MainActor in
                        self.appendSetupLine(line)
                    }
                }
            }

            await MainActor.run { finish(opening: path) }
        }
    }

    @MainActor
    private func appendSetupLine(_ line: String) {
        if case .settingUp(var log) = phase {
            log.append(line)
            phase = .settingUp(log: log)
        }
    }

    private func finish(opening path: String?) {
        if opensTerminal, let path { onOpenTerminal(path) }
        onDone()
    }
}
