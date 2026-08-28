import AppKit
import SwiftUI

/// A repository's open pull requests, in the order the list draws them.
///
/// Two groups, and the first one is why this exists: what the reader opened
/// or was handed is what they came to the list for, and it used to be mixed
/// in among everybody else's with an eight-point badge to tell them apart.
enum PullRequestListSplit {
    struct Result: Equatable {
        var mine: [GitStatusCenter.PullRequest]
        var others: [GitStatusCenter.PullRequest]
    }

    /// - Parameters:
    ///   - me: the signed-in `gh` login, or nil while it is not known yet.
    ///     Nil puts everything in `others`: claiming a pull request for a
    ///     reader whose name nobody has said is worse than claiming none.
    ///
    /// Order inside each group is `gh`'s own — newest first — because the
    /// only thing this decides is which group a row is in.
    static func split(_ prs: [GitStatusCenter.PullRequest], me: String?) -> Result {
        guard let me, !me.isEmpty else { return Result(mine: [], others: prs) }

        var mine: [GitStatusCenter.PullRequest] = []
        var others: [GitStatusCenter.PullRequest] = []
        for pr in prs {
            if pr.belongs(to: me) {
                mine.append(pr)
            } else {
                others.append(pr)
            }
        }
        return Result(mine: mine, others: others)
    }
}

/// Lists every open pull request of the repositories present in a group,
/// fetched on demand — one click opens the PR in the browser.
struct GroupPRListView: View {
    let group: SidebarGroup
    let openTabRoots: [String]

    @State private var roots: [String] = []
    @ObservedObject private var gitCenter: GitStatusCenter = .shared
    @ObservedObject private var palette: ThemePalette = .shared

    /// Repos a tab happens to be open in, plus — for a project (workspace)
    /// group — every repo discovered under its root, so one that nobody
    /// has a tab open in still shows up.
    private func resolveRoots() -> [String] {
        var found = Set(openTabRoots)
        if case .project(let root) = group.kind {
            found.formUnion(SidebarGroup.discoverRepoRoots(under: root))
        }
        // By project name rather than full path: workspaces group repos
        // that share a path prefix, but that's not guaranteed in general,
        // and the name is what the section header actually shows.
        return found.sorted {
            ($0 as NSString).lastPathComponent.localizedCaseInsensitiveCompare(
                ($1 as NSString).lastPathComponent
            ) == .orderedAscending
        }
    }

    /// Content taller than this scrolls instead of growing. A workspace
    /// with a few busy repos produces a list longer than the screen, and a
    /// popover that tall is both ugly and unusable — it covers the window
    /// it belongs to and runs off the bottom.
    ///
    /// The 60% budget is for the *popover*, so the title, the padding and
    /// the popover's own arrow come out of it instead of being added on
    /// top — capping only the list left the whole thing a little over.
    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(200, screen * 0.6 - 72)
    }

    /// Measured so the popover is only as tall as it needs to be. A bare
    /// `maxHeight` won't do: a `ScrollView` takes everything it is offered
    /// along its scroll axis, so two pull requests would get the same
    /// full-height popover as fifty.
    @State private var contentHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pull Requests")
                .font(palette.headlineFont)

            if roots.isEmpty {
                Text("No repositories in this group.")
                    .font(palette.captionFont)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                repoSections
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: PRListHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            .scrollIndicators(.automatic)
            .onPreferenceChange(PRListHeightKey.self) { height in
                contentHeight = height
            }
            .frame(height: contentHeight.map { min($0, maxListHeight) })
        }
        .padding(14)
        /// Wide enough to read a pull request title in. `feat(bc-provider):
        /// refuse a CNPJ that…` is where the old 340 points ran out, which
        /// is the half of the row that says what the change is.
        .frame(width: 460)
        .onAppear {
            roots = resolveRoots()
            roots.forEach { gitCenter.requestPRList(root: $0) }
            gitCenter.requestUserLogin()
        }
    }

    private var repoSections: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(roots, id: \.self) { root in
                VStack(alignment: .leading, spacing: 6) {
                    if roots.count > 1 {
                        Text((root as NSString).lastPathComponent)
                            .font(palette.font(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }

                    repoContent(root)
                }
            }
        }
    }

    @ViewBuilder
    private func repoContent(_ root: String) -> some View {
        if let prs = gitCenter.repoPRLists[root] {
            if prs.isEmpty {
                Text("No open pull requests.")
                    .font(palette.captionFont)
                    .foregroundStyle(.secondary)
            } else {
                let split = PullRequestListSplit.split(prs, me: gitCenter.userLogin)

                if !split.mine.isEmpty {
                    subsection("Yours", count: split.mine.count, emphasised: true)
                    cards(split.mine, mine: true)
                }

                if !split.others.isEmpty {
                    /// No header at all when nothing is the reader's. A lone
                    /// "Others" over the whole list is a label that separates
                    /// it from nothing.
                    if !split.mine.isEmpty {
                        subsection("Others", count: split.others.count, emphasised: false)
                    }
                    cards(split.others, mine: false)
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading…")
                    .font(palette.captionFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cards(_ prs: [GitStatusCenter.PullRequest], mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(prs) { pr in
                PullRequestCard(pr: pr, isMine: mine, me: gitCenter.userLogin, palette: palette) {
                    if let url = URL(string: pr.url) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    /// "Yours" rather than "Created by or assigned to me": the group holds
    /// both, and a header long enough to say so takes the width the titles
    /// under it need.
    private func subsection(_ title: String, count: Int, emphasised: Bool) -> some View {
        HStack(spacing: 4) {
            if emphasised {
                Image(systemName: "person.fill")
                    .font(.system(size: 8))
            }
            Text(title)
                .font(palette.font(size: 9.5, weight: .semibold))
                .textCase(.uppercase)
            Text(verbatim: "\(count)")
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .opacity(0.7)
            Spacer(minLength: 0)
        }
        .foregroundStyle(emphasised ? (palette.accent ?? .accentColor) : .secondary)
        .padding(.top, 2)
    }
}

private struct PRListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One pull request, shaped like the sidebar's own tab rows: a face on the
/// left, what it is on the first line, and the facts that place it on the
/// second.
///
/// Two lines rather than one because a title is the part people read and
/// `#434` is the part they act on, and squeezing both onto one line meant
/// truncating the title at about the point it started to say something.
private struct PullRequestCard: View {
    let pr: GitStatusCenter.PullRequest
    let isMine: Bool

    /// The signed-in login, for the one thing the section header cannot say:
    /// whether a pull request is the reader's because they opened it or
    /// because somebody handed it to them.
    let me: String?

    @ObservedObject var palette: ThemePalette
    let action: () -> Void

    @State private var isHovered = false

    private var accent: Color { palette.accent ?? .accentColor }

    /// Who opened it, and — when that is not the reader — that it is theirs
    /// anyway. Assigned pull requests are the ones a "your pull request"
    /// badge on the author never showed.
    private var attribution: String {
        let author = pr.author ?? "unknown"
        guard let me, !me.isEmpty else { return "Created by \(author)" }
        if pr.author?.lowercased() == me.lowercased() { return "Created by you" }
        if pr.belongs(to: me) { return "Created by \(author) · assigned to you" }
        return "Created by \(author)"
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                GitHubAvatarView(login: pr.author, size: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title)
                        .font(palette.font(size: 11.5, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 5) {
                        Text(verbatim: "#\(pr.number)")
                            .font(palette.font(size: 10, weight: .semibold))
                            .foregroundStyle(accent)

                        Text(attribution)
                            .font(palette.font(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11))
                    .foregroundStyle(isHovered ? accent : Color.secondary.opacity(0.6))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovered ? accent.opacity(0.12) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isMine ? accent.opacity(isHovered ? 0.5 : 0.28)
                            : Color.primary.opacity(isHovered ? 0.14 : 0.07))
            )
        }
        .buttonStyle(.plain)
        .help("Open #\(pr.number) in the browser")
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}
