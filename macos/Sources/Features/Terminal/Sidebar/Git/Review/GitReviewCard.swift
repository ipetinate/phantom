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

    @ViewBuilder
    private func content(_ context: GitReviewContext) -> some View {
        if let request = context.pullRequest {
            pullRequest(request)
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

        /// Where it is going, and why that is the target. The provenance is
        /// what tells a reader whether they are looking at what a pull request
        /// will merge or at a default somebody never chose.
        HStack(spacing: 4) {
            Text("\u{2192} \(context.target.ref)")
                .font(palette.font(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("(\(context.target.provenance))")
                .font(palette.font(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)
        }

        HStack(spacing: 5) {
            Text(count(context.commitCount, "commit"))
                .font(palette.font(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(count(context.fileCount, "file"))
                .font(palette.font(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

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

        conflictLine(context.conflicts)

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
        .padding(.top, 1)
    }

    @ViewBuilder
    private func pullRequest(_ request: GitReviewPullRequest) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: "#\(request.number)")
                .font(palette.font(size: 10, weight: .semibold))
                .foregroundStyle(palette.accent ?? .accentColor)
                .lineLimit(1)
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

            Spacer(minLength: 0)
        }

        if let preview = request.bodyPreview {
            Text(preview)
                .font(palette.font(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }

        /// Who and when, on one line. The update rather than the creation when
        /// both exist: a reader deciding whether to look at this wants to know
        /// whether anything has happened, and "opened three weeks ago" says
        /// the opposite of what "updated an hour ago" says about the same
        /// pull request.
        HStack(spacing: 4) {
            if let author = request.author {
                Text(author)
                    .font(palette.font(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let when = GitReviewPullRequest.relative(request.updatedAt ?? request.createdAt) {
                Text(request.updatedAt == nil ? "opened \(when)" : "updated \(when)")
                    .font(palette.font(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 0)
        }

        if !request.assignees.isEmpty {
            Text("Assigned: \(request.assignees.joined(separator: ", "))")
                .font(palette.font(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
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
