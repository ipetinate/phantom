import AppKit
import SwiftUI

/// Everything a branch will take to its target, before it takes it.
///
/// The local answer to a pull request's Files-changed tab, and deliberately
/// shaped like one: what is being compared and against what, then a way to
/// find a file, then the files themselves with their diffs inside. The
/// argument for it being local is that it is available *before* the push —
/// which is when knowing about a conflict is still cheap.
struct GitReviewPanelView: View {
    let scope: GitReviewScope
    let theme: CodeTheme
    let font: NSFont

    /// Opening a file for real, rather than reading it inside the review. A
    /// diff answers "what changed"; the editor answers "and now fix it", and
    /// the second belongs in a tab.
    let onOpenFile: (String) -> Void
    let onClose: () -> Void

    /// Opening one commit's own review, from the header's commit list.
    let onOpenCommit: (GitReviewCommit) -> Void

    @ObservedObject private var center: GitReviewCenter = .shared
    @ObservedObject private var palette: ThemePalette = .shared

    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var isPickingTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: theme.background).opacity(0.001))
        .task(id: scope.id) { center.load(root: scope.root) }
    }

    // MARK: The header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: scope.isCommit ? "checkmark.seal" : "arrow.triangle.pull")
                    .foregroundStyle(.secondary)

                Text(scope.title)
                    .font(palette.font(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                SidebarIconButton(help: "Refresh") {
                    center.load(root: scope.root, force: true)
                } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                }

                SidebarIconButton(help: "Close Review", action: onClose) {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
            }

            if case .ready(let context, let review) = center.state(for: scope.root) {
                summary(context)
                if !scope.isCommit { commitStrip(review) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The facts, in three groups with a rule between them.
    ///
    /// Everything used to be a chip, and a chip is a promise that something
    /// can be pressed. Twenty of them in five rows is what made this read as
    /// noise: the eye has nowhere to start, because nothing is quieter than
    /// anything else.
    ///
    /// So the rule now is that a chip means *actionable* — the target picker,
    /// the link out — and a fact is text. Grouped by the question it answers:
    /// what this is, where it goes and how big, and who did it.
    @ViewBuilder
    private func summary(_ context: GitReviewContext) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let request = context.pullRequest {
                pullRequestRow(request)
                Divider().opacity(0.5)
            }

            routeRow(context)
            sizeRow(context)
            conflictRow(context.conflicts)

            if !context.authors.isEmpty || context.pullRequest != nil {
                Divider().opacity(0.5)
                peopleRow(context)
            }
        }
    }

    /// What this is: the number, the title, and the way out to GitHub.
    ///
    /// The people moved to their own line. Two identical avatar chips side by
    /// side is what this produced when the author and the assignee are the
    /// same person, which is the common case on a branch somebody opened for
    /// themselves — and it said less than the words do.
    @ViewBuilder
    private func pullRequestRow(_ request: GitReviewPullRequest) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: "#\(request.number)")
                    .font(palette.font(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accent ?? .accentColor)
                    .fixedSize(horizontal: true, vertical: false)

                Text(request.title)
                    .font(palette.font(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if request.isDraft {
                    Text("Draft")
                        .font(palette.font(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.18)))
                        .fixedSize(horizontal: true, vertical: false)
                }

                Spacer(minLength: 8)

                if let when = GitReviewPullRequest.relative(
                    request.updatedAt ?? request.createdAt) {
                    Text(request.updatedAt == nil ? "opened \(when)" : "updated \(when)")
                        .font(palette.font(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Button("GitHub") {
                    if let url = URL(string: request.url) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.plain)
                .font(palette.font(size: 10))
                .foregroundStyle(palette.accent ?? .accentColor)
                .fixedSize(horizontal: true, vertical: false)
            }

            if let preview = request.bodyPreview {
                Text(preview)
                    .font(palette.font(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    /// Where the work is going, and the one control that changes it.
    @ViewBuilder
    private func routeRow(_ context: GitReviewContext) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            Text(context.branch)
                .font(palette.font(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Text("\u{2192}")
                .font(palette.font(size: 11))
                .foregroundStyle(.tertiary)

            Text(context.target.ref)
                .font(palette.font(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Text("(\(context.target.provenance))")
                .font(palette.font(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if !scope.isCommit { targetPicker }

            Spacer(minLength: 0)
        }
    }

    /// Changing what the branch is compared against.
    ///
    /// A chip, because it is one of the two things here that can be pressed —
    /// which is the whole reason the facts around it stopped being chips.
    ///
    /// A fetch is offered rather than performed: it is the network, and a
    /// picker that reached for it on open would stall the panel for a list
    /// most readers will not change.
    @ViewBuilder
    private var targetPicker: some View {
        Menu {
            Button("Refresh branches (fetch)") {
                center.loadBranches(root: scope.root, fetching: true)
            }
            Divider()
            ForEach(center.branches[scope.root] ?? [], id: \.self) { branch in
                Button(branch) { center.choose(target: branch, root: scope.root) }
            }
        } label: {
            chip(icon: "arrow.left.arrow.right", text: "Compare against\u{2026}")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onAppear {
            if center.branches[scope.root] == nil {
                center.loadBranches(root: scope.root, fetching: false)
            }
        }
    }

    /// How much of it there is. One line, separated by dots rather than boxed
    /// individually — they are read together or not at all.
    @ViewBuilder
    private func sizeRow(_ context: GitReviewContext) -> some View {
        HStack(spacing: 5) {
            fact(countLabel(context.commitCount, "commit"))
            dot
            fact(countLabel(context.fileCount, "file"))
            dot

            Text(verbatim: "+\(context.addedLines)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.green)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(verbatim: "\u{2212}\(context.removedLines)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.red)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)
        }
    }

    /// The one line that is a warning. It keeps its colour and its icon,
    /// because it is the only thing here a reader has to act on.
    @ViewBuilder
    private func conflictRow(_ check: GitReviewConflictCheck) -> some View {
        HStack(spacing: 5) {
            Image(systemName: conflictIcon(check))
                .font(.system(size: 9, weight: .semibold))
            Text(check.summary)
                .font(palette.font(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(conflictTint(check))
        .help(conflictHelp(check))
    }

    /// Who, on one line, with the roles named rather than implied by an icon.
    ///
    /// Two identical avatars side by side is what the icons produced when the
    /// author and the assignee are the same person, which is the common case
    /// on a branch somebody opened for themselves.
    @ViewBuilder
    private func peopleRow(_ context: GitReviewContext) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let request = context.pullRequest {
                HStack(spacing: 5) {
                    if let author = request.author {
                        label("Opened by", author)
                    }
                    if !request.assignees.isEmpty {
                        if request.author != nil { dot }
                        label("Assigned to", request.assignees.joined(separator: ", "))
                    }
                    Spacer(minLength: 0)
                }
            }

            if !context.authors.isEmpty {
                HStack(spacing: 5) {
                    label(
                        "Commits by",
                        context.authors.prefix(4)
                            .map { "\($0.name) (\($0.commits))" }
                            .joined(separator: ", "))
                    Spacer(minLength: 0)
                }
                .help(context.authors.map { "\($0.name): \($0.commits)" }
                    .joined(separator: "\n"))
            }
        }
    }

    private func conflictIcon(_ check: GitReviewConflictCheck) -> String {
        switch check {
        case .clean: return "checkmark.circle"
        case .conflicting: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func conflictTint(_ check: GitReviewConflictCheck) -> Color {
        switch check {
        case .clean: return .green
        case .conflicting: return Color(nsColor: .systemRed)
        case .unknown: return .secondary
        }
    }

    private func conflictHelp(_ check: GitReviewConflictCheck) -> String {
        switch check {
        case .clean: return "This branch merges into its target cleanly."
        case .conflicting(let paths): return paths.joined(separator: "\n")
        case .unknown:
            return "Git could not compute the merge \u{2014} an unrelated history, "
                + "or a target it cannot find."
        }
    }

    @ViewBuilder
    private func fact(_ text: String) -> some View {
        Text(text)
            .font(palette.font(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func label(_ name: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(name)
                .font(palette.font(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(palette.font(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var dot: some View {
        Text("\u{00B7}")
            .font(palette.font(size: 10))
            .foregroundStyle(.quaternary)
    }

    /// The commits, each one a way into its own review.
    @ViewBuilder
    private func commitStrip(_ review: GitBranchReview) -> some View {
        if !review.commits.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(review.commits) { commit in
                        Button {
                            onOpenCommit(commit)
                        } label: {
                            HStack(spacing: 4) {
                                Text(commit.shortSha)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(commit.subject)
                                    .font(palette.font(size: 10))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.secondary.opacity(0.10)))
                        }
                        .buttonStyle(.plain)
                        .help("\(commit.author) \u{2022} \(commit.relativeDate)")
                    }
                }
            }
        }
    }

    // MARK: The files

    @ViewBuilder
    private var content: some View {
        switch center.state(for: scope.root) {
        case .none, .loading:
            centered("Reading what this branch changes\u{2026}")

        case .failed(let message):
            centered(message)

        case .ready(let context, let review):
            let files = filtered(review.files)
            VStack(spacing: 0) {
                search(total: review.files.count, shown: files.count)
                Divider()
                if files.isEmpty {
                    centered(review.files.isEmpty
                        ? "Nothing changes against the target."
                        : "No file matches \u{201C}\(query)\u{201D}.")
                } else {
                    fileList(files, target: context.target.ref)
                }
            }
        }
    }

    @ViewBuilder
    private func search(total: Int, shown: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            TextField("Filter files", text: $query)
                .textFieldStyle(.plain)
                .font(palette.font(size: 11))

            if !query.isEmpty {
                Text(verbatim: "\(shown)/\(total)")
                    .font(palette.font(size: 10))
                    .foregroundStyle(.tertiary)
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func fileList(_ files: [GitReviewFile], target: String) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(files) { file in
                    GitReviewFileCard(
                        file: file,
                        scope: scope,
                        theme: theme,
                        font: font,
                        target: target,
                        isExpanded: expanded.contains(file.path),
                        onToggle: { toggle(file.path) },
                        onOpenFile: { onOpenFile(file.path) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: Pieces

    /// Matching on the whole path, not the name.
    ///
    /// A branch that touches four `index.ts` is the normal case in a module
    /// tree, and filtering by name alone would leave the reader picking among
    /// four identical rows. Case-insensitive because nobody types the case of
    /// a path they are searching for.
    private func filtered(_ files: [GitReviewFile]) -> [GitReviewFile] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return files }
        return files.filter { $0.path.lowercased().contains(needle) }
    }

    private func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
        }
    }

    private func countLabel(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private func chip(
        icon: String,
        text: String,
        tint: Color? = nil,
        help: String? = nil
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(palette.font(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill((tint ?? .secondary).opacity(0.12)))
        .help(help ?? text)
    }

    @ViewBuilder
    private func centered(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(palette.font(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
