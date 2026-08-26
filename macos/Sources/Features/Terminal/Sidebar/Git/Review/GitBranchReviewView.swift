import SwiftUI

/// What this branch would put in a pull request: the commits it adds and the
/// files it changes, measured against the point it left its base.
///
/// Above the working-tree sections rather than beside them, because it answers
/// a different question. Those say "what have I not committed"; this says "what
/// am I about to ask somebody to read", and it is the question you have right
/// before opening a pull request — the moment this whole panel exists to serve.
///
/// Collapsed by default. It costs a `git log` and a `git diff` to fill, and
/// most of the time somebody opening the Git panel is looking at their
/// uncommitted work, not at their branch.
struct GitBranchReviewView: View {
    let root: String

    /// Opens the full-size review of this branch, and of one commit in it.
    ///
    /// Callbacks rather than this view reaching for the editor: the sidebar
    /// does not own the pane the review appears in, and a view that could
    /// reach across to it would be a view able to replace what the reader is
    /// looking at from anywhere.
    var onOpenReview: (() -> Void)?
    var onOpenCommit: ((GitReviewCommit) -> Void)?
    let onOpenDiff: (GitReviewFile, GitReviewBase) -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @State private var isExpanded = false
    @State private var outcome: GitBranchReviewOutcome?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                content
                    .padding(.top, 4)
            }
        }
        .onChange(of: isExpanded) { expanded in
            if expanded, outcome == nil { load() }
        }
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("Branch Review")
                    .font(palette.font(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if let review = loadedReview {
                    SidebarCountBadge(count: review.commits.count)
                }

                Spacer(minLength: 0)

                if isExpanded {
                    /// The way into the full-size review. Here rather than at
                    /// the bottom of the list because it is the thing most
                    /// readers open this section to do — the list is the
                    /// summary, and the panel is the work.
                    SidebarIconButton(help: "Review this branch") {
                        onOpenReview?()
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    SidebarIconButton(help: "Refresh Branch Review") { load() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 4)
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch outcome {
        case nil:
            note(isLoading ? "Reading the branch…" : "")

        case .failed(let failure):
            note(failure.summary ?? failure.title)

        case .tooLarge(let bytes):
            note("This branch changes more than this pane can list (\(bytes / 1024) KB of diff).")

        case .review(let review):
            reviewBody(review)
        }
    }

    @ViewBuilder
    private func reviewBody(_ review: GitBranchReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            /// Each of these is a real state somebody hits, and each needs a
            /// sentence rather than an empty list — an empty list of changes
            /// reads as "your branch is clean", which is a different and
            /// wrong answer.
            if review.head == nil {
                note("This repository has no commits yet.")
            } else if let base = review.base {
                baseLine(base, review: review)

                if review.commits.isEmpty {
                    note("This branch is level with \(base.ref) — nothing to review.")
                } else {
                    commitList(review)
                    fileList(review, base: base)
                }
            } else if let branch = review.branch {
                /// Both halves of what ``GitBranchReviewLoader/resolveBase(in:branch:)``
                /// came back empty-handed about, because either alone reads
                /// as a bug in the pane: no `origin/HEAD` to fall back on,
                /// and no ``GitBranchReviewLoader/wellKnownBases`` name that
                /// isn't this branch — the search steps over a candidate
                /// equal to the current branch, so `main` cannot be its own
                /// base.
                ///
                /// The advice is conditioned rather than given flat, because
                /// it only works one way round. Publishing `main` produces
                /// `origin/main`, a different ref from `main`, which
                /// `wellKnownBases` then resolves. Publishing `feature-x` in
                /// a repository that has no main or master at all produces
                /// `origin/feature-x` — the branch's own remote counterpart,
                /// which is not a base — and leaves this note exactly where
                /// it was.
                ///
                /// It deliberately does not offer to pick a base. The loader
                /// takes one, but nothing in the app passes it: the single
                /// call site is `load(in: root)`. Naming an affordance that
                /// does not exist sends the reader looking for a control
                /// that was never built.
                note("No remote default branch, and no main or master other than \(branch) — nothing here to compare against. If \(branch) is this project's base, publishing it with git push -u origin \(branch) gives the review something to compare with.")
            } else {
                note("HEAD is detached, so there is no branch to compare.")
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    private func baseLine(_ base: GitReviewBase, review: GitBranchReview) -> some View {
        HStack(spacing: 4) {
            Text("vs \(base.ref)")
                .font(palette.font(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(base.source.summary)
                .font(palette.font(size: 9))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)

            Text(totals(review))
                .font(palette.font(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    /// Added and removed across the branch, and how many files are binary.
    ///
    /// Binary files are counted apart rather than folded in as zeroes: git
    /// reports no line counts for them, and showing `0` would claim they did
    /// not change.
    private func totals(_ review: GitBranchReview) -> String {
        let added = review.files.compactMap(\.addedLines).reduce(0, +)
        let removed = review.files.compactMap(\.removedLines).reduce(0, +)
        let binary = review.files.filter(\.isBinary).count

        var parts = ["+\(added)", "−\(removed)"]
        if binary > 0 { parts.append("\(binary) binary") }
        return parts.joined(separator: "  ")
    }

    @ViewBuilder
    private func commitList(_ review: GitBranchReview) -> some View {
        ForEach(review.commits) { commit in
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(commit.shortSha)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Text(commit.subject)
                    .font(palette.font(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                /// Never wrapped, and never the thing that shrinks.
                ///
                /// `layoutPriority(-1)` alone told SwiftUI to take space from
                /// this first, and with nothing forbidding a second line it
                /// took it one character at a time — a commit with a long
                /// subject left "5 days ago" running down the panel as a
                /// column of letters. The subject is the part with room to
                /// give, and it already truncates.
                Text(commit.relativeDate)
                    .font(palette.font(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            /// The whole row, because every part of it identifies the same
            /// commit. A hit target on the sha alone would be seven
            /// characters wide.
            .contentShape(Rectangle())
            .onTapGesture { onOpenCommit?(commit) }
            .help("Review \(commit.shortSha) \u{2014} \(commit.author)")
        }

        if review.hasMoreCommits {
            note("More commits than shown — this list is capped.")
        }
    }

    @ViewBuilder
    private func fileList(_ review: GitBranchReview, base: GitReviewBase) -> some View {
        if !review.files.isEmpty {
            Divider().padding(.vertical, 2)

            ForEach(review.files) { file in
                Button {
                    onOpenDiff(file, base)
                } label: {
                    GitBranchReviewFileRow(file: file)
                }
                .buttonStyle(.plain)
                .help(file.path)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(palette.font(size: 10))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
    }

    private var loadedReview: GitBranchReview? {
        if case .review(let review) = outcome { return review }
        return nil
    }

    /// Read off the main actor: this runs `git log` and `git diff`, and a
    /// branch a long way from its base makes both of them slow enough to drop
    /// a frame on the click that asked for them.
    private func load() {
        isLoading = true
        let root = root

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                GitBranchReviewLoader.load(in: root)
            }.value

            await MainActor.run {
                outcome = result
                isLoading = false
            }
        }
    }
}

/// One changed file in the review.
private struct GitBranchReviewFileRow: View {
    let file: GitReviewFile

    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var icons: FileIconProvider = .shared
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            FileIconView(icon: icons.icon(forFile: file.name), size: 12)

            Text(file.name)
                .font(palette.font(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)

            if !file.directory.isEmpty {
                Text(file.directory)
                    .font(palette.font(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 4)

            /// The counts, or the word for a file that has none. A binary file
            /// showing `+0 −0` would read as unchanged.
            /// All three held to one line for the reason the commit row's
            /// date is: a long path leaves these as the only things with space
            /// to give, and a count that wraps is a count read downwards.
            if let added = file.addedLines, let removed = file.removedLines {
                Text("+\(added)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text("−\(removed)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text("binary")
                    .font(palette.font(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text(file.status.badge)
                .font(palette.font(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 12)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.secondary.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

