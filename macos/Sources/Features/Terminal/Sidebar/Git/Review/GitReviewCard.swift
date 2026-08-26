import AppKit
import SwiftUI

/// The state of the work on this branch, at a glance, in the sidebar.
///
/// The question it answers is the one somebody has with a hand on the push:
/// what is on this branch, where is it going, and is anything in the way. The
/// full review is a click away and this is deliberately not a small copy of
/// it — no file list, no diff. Four facts and a way in.
///
/// **It loads when the section is expanded, not when the panel opens.** That
/// costs a `gh pr view` and a `git merge-tree`, which is the price of the two
/// things nobody can infer from the row above: whether there is a pull request
/// and whether the merge would conflict. The section is collapsed by default,
/// so expanding it is already the reader asking.
struct GitReviewCard: View {
    let root: String
    let onOpenReview: () -> Void

    @ObservedObject private var center: GitReviewCenter = .shared
    @ObservedObject private var palette: ThemePalette = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch center.state(for: root) {
            case .none, .loading:
                Text("Reading this branch\u{2026}")
                    .font(palette.font(size: 10))
                    .foregroundStyle(.tertiary)

            case .failed(let message):
                Text(message)
                    .font(palette.font(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)

            case .ready(let context, _):
                content(context)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.09)))
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .task(id: root) { center.load(root: root) }
    }

    /// Three groups with a rule between them, in a card the width of a
    /// sidebar.
    ///
    /// The same discipline as the panel's header and for the same reason: a
    /// flat stack of seven rows has no shape, so the eye reads it top to
    /// bottom every time instead of jumping to the part it wanted. Grouped by
    /// the question each answers — what this is, where it goes and how big,
    /// who did it — a reader looking for the conflict line finds it without
    /// reading the rest.
    ///
    /// Tighter than the panel's version because the room is a third of it: no
    /// icons beside the facts, and the counts share a line.
    @ViewBuilder
    private func content(_ context: GitReviewContext) -> some View {
        identity(context)

        rule

        route(context)

        /// On the target itself there is nothing to size and nothing to check.
        /// Saying so beats a row of zeros and a green tick, which together
        /// read as approval of work that does not exist.
        if context.isOnTarget {
            labelled("Nothing to review", "this branch is the target")
        } else {
            size(context)
            conflictLine(context.conflicts)
        }

        if context.pullRequest != nil || !context.authors.isEmpty {
            rule
            people(context)
        }

        /// No way in when there is nothing behind it. A panel that opens onto
        /// "nothing changes against the target" is a click that answers a
        /// question the card already answered.
        if !context.isOnTarget, !context.isEmpty {
            reviewButton
        }
    }

    @ViewBuilder
    private var reviewButton: some View {
        Button(action: onOpenReview) {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 9, weight: .semibold))
                Text("Review this work")
                    .font(palette.font(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill((palette.accent ?? .accentColor).opacity(0.22)))
        }
        .buttonStyle(.plain)
        .padding(.top, 3)
    }

    /// What this is: the pull request when there is one, the branch when there
    /// is not.
    @ViewBuilder
    private func identity(_ context: GitReviewContext) -> some View {
        if let request = context.pullRequest {
            HStack(spacing: 4) {
                Text(verbatim: "#\(request.number)")
                    .font(palette.font(size: 10, weight: .semibold))
                    .foregroundStyle(palette.accent ?? .accentColor)
                    .fixedSize(horizontal: true, vertical: false)

                Text(request.title)
                    .font(palette.font(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if request.isDraft {
                    Text("Draft")
                        .font(palette.font(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.18)))
                        .fixedSize(horizontal: true, vertical: false)
                }

                Spacer(minLength: 4)

                /// The way out to the browser, wherever a pull request is
                /// named. A glyph rather than the word "GitHub", because in a
                /// sidebar the label would cost more room than the title it
                /// sits beside — and the arrow is the same one the file rows
                /// in the review use for "open this elsewhere".
                if let url = URL(string: request.url) {
                    SidebarIconButton(help: "Open #\(request.number) on GitHub") {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let preview = request.bodyPreview {
                Text(preview)
                    .font(palette.font(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(context.branch)
                    .font(palette.font(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
    }

    /// Where it is going, and why that is the target. The provenance is what
    /// tells a reader whether they are looking at what a pull request will
    /// merge or at a default nobody chose.
    @ViewBuilder
    private func route(_ context: GitReviewContext) -> some View {
        HStack(spacing: 4) {
            Text("\u{2192}")
                .font(palette.font(size: 10))
                .foregroundStyle(.quaternary)
                .fixedSize(horizontal: true, vertical: false)

            Text(context.target.ref)
                .font(palette.font(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(context.target.provenance)
                .font(palette.font(size: 9))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)
        }
    }

    /// How much of it there is, on one line. They are read together or not at
    /// all, so they are not boxed individually.
    @ViewBuilder
    private func size(_ context: GitReviewContext) -> some View {
        HStack(spacing: 4) {
            fact(count(context.commitCount, "commit"))
            dot
            fact(count(context.fileCount, "file"))
            dot

            Text(verbatim: "+\(context.addedLines)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.green)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(verbatim: "\u{2212}\(context.removedLines)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.red)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)
        }
    }

    /// Who, with the roles named rather than left to an icon.
    ///
    /// The update rather than the creation when both exist: a reader deciding
    /// whether to look at this wants to know whether anything has happened,
    /// and "opened three weeks ago" says the opposite of "updated an hour ago"
    /// about the same pull request.
    @ViewBuilder
    private func people(_ context: GitReviewContext) -> some View {
        if let request = context.pullRequest {
            if let author = request.author {
                labelled("Opened by", author)
            }
            if !request.assignees.isEmpty {
                labelled("Assigned to", request.assignees.joined(separator: ", "))
            }
            if let when = GitReviewPullRequest.relative(
                request.updatedAt ?? request.createdAt) {
                labelled(request.updatedAt == nil ? "Opened" : "Updated", when)
            }
        }

        if !context.authors.isEmpty {
            labelled(
                "Commits by",
                context.authors.prefix(3)
                    .map { "\($0.name) (\($0.commits))" }
                    .joined(separator: ", ")
            )
            .help(context.authors.map { "\($0.name): \($0.commits)" }
                .joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func labelled(_ name: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(name)
                .font(palette.font(size: 9))
                .foregroundStyle(.quaternary)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(palette.font(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func fact(_ text: String) -> some View {
        Text(text)
            .font(palette.font(size: 9))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var dot: some View {
        Text("\u{00B7}")
            .font(palette.font(size: 9))
            .foregroundStyle(.quaternary)
    }

    /// Thinner than a `Divider` on purpose: in a card this size a full-weight
    /// rule reads as a border and looks like the card ending.
    private var rule: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(height: 1)
            .padding(.vertical, 1)
    }

    /// The one line that is a warning rather than a fact.
    @ViewBuilder
    private func conflictLine(_ check: GitReviewConflictCheck) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon(for: check))
                .font(.system(size: 8, weight: .semibold))
            Text(check.summary)
                .font(palette.font(size: 9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint(for: check))
        .help(helpText(for: check))
    }

    private func icon(for check: GitReviewConflictCheck) -> String {
        switch check {
        case .clean: return "checkmark.circle"
        case .conflicting: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func tint(for check: GitReviewConflictCheck) -> Color {
        switch check {
        case .clean: return .green
        case .conflicting: return Color(nsColor: .systemRed)
        case .unknown: return .secondary
        }
    }

    private func helpText(for check: GitReviewConflictCheck) -> String {
        switch check {
        case .clean: return "This branch merges into its target cleanly."
        case .conflicting(let paths): return paths.joined(separator: "\n")
        case .unknown:
            return "Git could not compute the merge \u{2014} an unrelated history, "
                + "or a target it cannot find."
        }
    }

    private func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}
