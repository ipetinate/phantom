import Combine
import SwiftUI

/// The other direction: from what you are working on to where you want to
/// work on it.
///
/// A **chooser**, not a form. The create sheet already asks for a name, a
/// base, a path preview and shows a setup log, and none of that fits a
/// 240pt column hanging off a row — so anything that needs answering opens
/// that sheet, and this stays a list you point at.
struct WorktreePopover: View {
    /// What pressing a row means. Decided by `WorktreeEntryRule` at the
    /// place the button lives, not here, so this view never has to reason
    /// about whether a terminal is busy.
    let action: WorktreeEntryAction

    /// One family, or several — the same distinction the panel draws, and
    /// the same type drawing it. A group header standing for
    /// `~/Projects/Aurora` reaches six repositories, and a chooser that can
    /// only hold one was the reason that button had nothing to show.
    let scope: WorktreeScope

    /// The worktree the terminal is in. Excluded from the list when
    /// migrating — "switch to where you already are" is not a choice — and
    /// used to name where unsaved files will stay.
    let currentPath: String?

    @ObservedObject var editorCenter: EditorCenter

    /// The working directory of every terminal in this window, which is all
    /// the occupancy count needs. Passed in rather than read from a manager
    /// here so this view keeps one dependency instead of two, and so the
    /// count can be exercised without terminals.
    let terminalPwds: [String]

    /// Applies a migration the reader has confirmed: the shell `cd`s, and
    /// the plan's `migrate` half is carried out.
    let onMigrate: (GitWorktree, [WorktreeDocumentMigration.Outcome]) -> Void

    let onNewTerminal: (String) -> Void

    /// Opens the create sheet for one family, which is where every question
    /// lives. The family is named rather than assumed: with several on
    /// screen there is no "the" repository to create in.
    let onNewWorktree: (String) -> Void

    /// Groups the terminals of one worktree together. Offered here because
    /// three terminals in one worktree usually *are* a group, and this is
    /// the moment the reader is thinking about that worktree.
    ///
    /// Nil where there is nothing sensible to group — from inside a group's
    /// own header, where the group already exists. The item is then not
    /// drawn at all, rather than drawn and inert: a menu item that does
    /// nothing when pressed is worse than one that isn't there.
    let onCreateGroup: ((GitWorktree) -> Void)?

    /// Cancels the switch and goes to the file — see
    /// `WorktreeMigrationConfirm.onView`.
    let onViewFile: (String) -> Void

    let dismiss: () -> Void

    @ObservedObject private var center: WorktreeCenter = .shared
    @ObservedObject private var git: GitCenter = .shared
    @ObservedObject private var palette: ThemePalette = .shared

    /// Set once the reader has pointed at a worktree and there is something
    /// to say before going there.
    @State private var confirming: GitWorktree?

    /// The plan for `confirming`, recomputed while the popover is open.
    ///
    /// State rather than a computed property because computing it touches
    /// the filesystem once per open tab, and `body` runs far more often than
    /// the answer changes. Recomputed on the one thing that can change it
    /// from in here — a file being saved, which the editor publishes as a
    /// change to its tab set.
    @State private var plan: [WorktreeDocumentMigration.Outcome] = []

    /// Which repository sections are open, in the several-families case.
    ///
    /// Absence is what costs nothing: listing a family is a `git worktree
    /// list`, and a folder of twenty repositories opened indiscriminately is
    /// twenty subprocesses for a list nobody has looked at yet. Expanding one
    /// is what buys it — the panel's rule, stated in `WorktreeScope.polled`.
    @State private var expanded: Set<String> = []

    /// What the reader is looking for. Everything is listed until there is
    /// something here.
    @State private var query = ""

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        Group {
            if let target = confirming {
                confirm(target)
            } else {
                chooser
            }
        }
        .onChange(of: editorCenter.tabs) { _ in refreshPlan() }
        /// Typing is what pays for a workspace's lists.
        ///
        /// A collapsed section has deliberately never been listed — see
        /// `WorktreeScope.polled` — so a query would have nothing to narrow
        /// in it, and the field would read as broken in the one case it
        /// exists for. Unforced, so the store answers out of its TTL and the
        /// next letter costs no subprocess.
        .onChange(of: query) { _ in
            guard !query.isEmpty else { return }
            for root in scope.roots {
                center.requestList(commonRoot: root)
            }
        }
        /// Asked for again while this is open, which is what the panel does
        /// and for the same reason: `git worktree list` answers off the main
        /// thread, and a popover opened before it came back showed an empty
        /// chooser for as long as it stayed up. Every request inside the
        /// store's TTL is a no-op, so this costs nothing once the answer has
        /// landed.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            for root in scope.polled(expanded: expanded) {
                center.requestList(commonRoot: root)
            }
        }
    }

    // MARK: Choosing

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(action == .migrate ? "Switch This Terminal To" : "Open a Terminal In")
                .font(palette.font(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            /// Nothing to search where there is no list at all.
            if !scope.roots.isEmpty {
                search
            }

            /// Height reserved up front, with a floor, rather than taken
            /// from the content.
            ///
            /// A popover sizes itself to its content when it is presented
            /// and does not grow afterwards. The worktree list arrives from
            /// a `git worktree list` off the main thread, so a popover
            /// opened a moment earlier laid out around the empty state and
            /// then clamped the arriving rows into ten points of height:
            /// two rows that existed, had scrollers, and drew nothing. The
            /// floor is what makes the box the same size before and after
            /// the answer lands.
            ///
            /// It is also what lets a section be opened at all: the box is
            /// the fixed thing and the sections scroll inside it, so
            /// expanding one does not ask the popover to grow after the fact.
            ZStack(alignment: .topLeading) {
                switch scope {
                case .repository(let root):
                    family(root)
                case .workspace(let roots):
                    sections(roots)
                case .none:
                    EmptyView()
                }
            }
            .frame(height: listHeight, alignment: .topLeading)

            if case .repository(let root) = scope {
                Divider().padding(.vertical, 2)

                Button {
                    leaving { onNewWorktree(root) }
                } label: {
                    Label("New Worktree…", systemImage: "plus")
                        .font(palette.font(size: 11))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)

                /// Set apart by a gap rather than by a second box: it is a
                /// different kind of action, but it is about the same thing
                /// the reader is already looking at.
                ///
                /// One family only. It needs a single worktree to be about,
                /// and a list of repositories is not one — from a workspace
                /// the reader has not yet said which repository they mean.
                if let onCreateGroup, let groupable = currentWorktree ?? offered(in: root).first {
                    Button {
                        leaving { onCreateGroup(groupable) }
                    } label: {
                        Label("Create Group from Worktree", systemImage: "folder.badge.plus")
                            .font(palette.font(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
            }
        }
        .padding(8)
        .frame(width: width)
        /// Forced, because the answer may be a cached empty one: the store
        /// stamps its check time even when git failed, so an unforced
        /// request inside the TTL would decline to ask again and the chooser
        /// would stay empty on the strength of one bad answer.
        .onAppear {
            openingSections()
            isSearchFocused = true
        }
    }

    /// Wider with sections than without: a repository name and a branch name
    /// on the same 260 points leaves neither of them readable.
    private var width: CGFloat {
        switch scope {
        case .workspace: return 320
        default: return 260
        }
    }

    /// Room for three rows even when there are none yet, and never more
    /// than six — past that the list scrolls rather than the popover growing
    /// down the screen.
    ///
    /// Fixed at the ceiling for sections, because that is the case where the
    /// content changes size after the popover is up.
    ///
    /// Measured on the unfiltered list, which is the same reason again: a box
    /// sized to the three rows a query left would clip the rows that come
    /// back when the query is cleared.
    private var listHeight: CGFloat {
        switch scope {
        case .repository(let root):
            return CGFloat(min(max(offered(in: root).count, 3), 6)) * 28
        case .workspace:
            return 6 * 28
        case .none:
            return 28
        }
    }

    // MARK: Searching

    /// The Git pickers' search row, in this popover's vocabulary.
    ///
    /// It owes the reader what `BranchPicker.search` owes them, and for the
    /// same reason: thirty-five entries is a list nobody wants to point at.
    /// Focused on open, so typing narrows immediately; Return takes the first
    /// match, so the whole gesture is type and press.
    private var search: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            TextField("Search worktrees", text: $query)
                .textFieldStyle(.plain)
                .font(palette.font(size: 11))
                .focused($isSearchFocused)
                .onSubmit {
                    guard let first = firstMatch else { return }
                    choose(first)
                }

            if !query.isEmpty {
                Text(verbatim: "\(shownCount)/\(totalCount)")
                    .font(palette.font(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                Button {
                    query = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func shown(in root: String) -> [GitWorktree] {
        WorktreeChooserFilter.matches(offered(in: root), query: query, name: name(of:))
    }

    /// The sections a workspace draws, in `WorktreeScope`'s order and with
    /// the query applied inside each.
    private func shownSections(_ roots: [String]) -> [WorktreeChooserSection] {
        WorktreeChooserFilter.sections(
            roots.map { root in
                WorktreeChooserSection(
                    root: root,
                    worktrees: offered(in: root),
                    isListed: center.hasLoaded(root))
            },
            query: query,
            name: name(of:))
    }

    /// Return's answer: the first row still drawn, which in a workspace is
    /// the first match of the first section that has one.
    private var firstMatch: GitWorktree? {
        switch scope {
        case .repository(let root):
            return shown(in: root).first
        case .workspace(let roots):
            return shownSections(roots).compactMap { $0.worktrees.first }.first
        case .none:
            return nil
        }
    }

    private var shownCount: Int {
        switch scope {
        case .repository(let root):
            return shown(in: root).count
        case .workspace(let roots):
            return shownSections(roots).reduce(0) { $0 + $1.worktrees.count }
        case .none:
            return 0
        }
    }

    private var totalCount: Int {
        scope.roots.reduce(0) { $0 + offered(in: $1).count }
    }

    private var noMatch: String {
        "No worktree matches \u{201C}\(query)\u{201D}."
    }

    /// Three ways for one family to have nothing to draw, and three
    /// sentences for them. The unfiltered list is what tells the third
    /// apart: a repository that has rows and draws none of them was narrowed
    /// to nothing, and "this is the only worktree" over that answers a
    /// question nobody asked.
    private func emptyText(for root: String) -> String {
        offered(in: root).isEmpty ? emptyMessage(for: root) : noMatch
    }

    // MARK: One family

    private func family(_ root: String) -> some View {
        let list = shown(in: root)
        return Group {
            if list.isEmpty {
                Text(emptyText(for: root))
                    .font(palette.font(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(list) { worktree in
                            row(worktree)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    // MARK: Several families

    private func sections(_ roots: [String]) -> some View {
        let shown = shownSections(roots)
        return Group {
            if shown.isEmpty {
                Text(noMatch)
                    .font(palette.font(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown, id: \.root) { item in
                            section(item)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    @ViewBuilder
    private func section(_ section: WorktreeChooserSection) -> some View {
        let root = section.root

        /// Open while there is a query, whichever sections the reader had
        /// clicked. A field that narrowed six sections and left the matches
        /// behind five closed triangles would hide its own answer.
        let isOpen = expanded.contains(root) || !query.isEmpty

        Button {
            toggle(root)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 9)

                Text((root as NSString).lastPathComponent)
                    .font(palette.font(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                /// Only once the list is in. Asking for a count is asking
                /// for the list, and a collapsed section is a section that
                /// has deliberately not asked.
                if !section.worktrees.isEmpty {
                    Text(verbatim: "\(section.worktrees.count)")
                        .font(.system(size: 9.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(WorktreePopoverRowStyle())

        if isOpen {
            Group {
                if section.worktrees.isEmpty {
                    Text(emptyMessage(for: root))
                        .font(palette.font(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                } else {
                    ForEach(section.worktrees) { worktree in
                        row(worktree)
                    }
                }

                /// Left out while filtering: every other row under an open
                /// section is one the query kept, and a row that ignores the
                /// query is one the eye rules out again on every letter.
                if query.isEmpty {
                    Button {
                        leaving { onNewWorktree(root) }
                    } label: {
                        Label("New Worktree…", systemImage: "plus")
                            .font(palette.font(size: 10.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(WorktreePopoverRowStyle())
                }
            }
            .padding(.leading, 14)
        }
    }

    /// Opening a section is what pays for its list, so the request goes here
    /// rather than waiting for the next tick: a second of an empty section
    /// after a click reads as a click that missed.
    private func toggle(_ root: String) {
        if expanded.contains(root) {
            expanded.remove(root)
        } else {
            expanded.insert(root)
            center.requestList(commonRoot: root, force: true)
        }
    }

    /// Which sections start open, and what that costs.
    ///
    /// One or two families are opened for the reader: two lists is the same
    /// pair of subprocesses the flat chooser has always paid for, and asking
    /// somebody to click twice to reach a branch they can see the repository
    /// of is a click for nothing. Three or more stay shut.
    private func openingSections() {
        let roots = scope.roots
        if case .workspace = scope, roots.count <= 2 {
            expanded = Set(roots)
        }
        for root in scope.polled(expanded: expanded) {
            center.requestList(commonRoot: root, force: true)
        }
    }

    // MARK: Rows

    private func row(_ worktree: GitWorktree) -> some View {
        Button {
            choose(worktree)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: worktree.isMain ? "house" : "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 13)

                Text(name(of: worktree))
                    .font(palette.font(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let status = git.status(forRoot: worktree.path), !status.isClean {
                    Circle().fill(.yellow).frame(width: 5, height: 5)
                }

                Spacer(minLength: 4)

                /// How many terminals are already there. Not a warning —
                /// several terminals in one worktree is the normal way to
                /// work — but it is the difference between arriving somewhere
                /// empty and joining something in progress.
                let occupants = occupantCount(worktree)
                if occupants > 0 {
                    Text(verbatim: "\(occupants)")
                        .font(.system(size: 9.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "terminal")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                }

                if worktree.isLocked {
                    Image(systemName: "lock")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(WorktreePopoverRowStyle())
    }

    /// Bare and prunable entries are dropped: one has no working tree to
    /// `cd` into, the other's folder is already gone. Offering either would
    /// be offering a destination that does not exist.
    private func offered(in root: String) -> [GitWorktree] {
        center.list(forRoot: root).filter { worktree in
            guard !worktree.isBare, !worktree.isPrunable else { return false }
            guard action == .migrate else { return true }
            return !GitWorktreeMembership.contains(pwd: currentPath, root: worktree.path)
        }
    }

    private var currentWorktree: GitWorktree? {
        for root in scope.roots {
            if let here = center.list(forRoot: root).first(where: {
                GitWorktreeMembership.contains(pwd: currentPath, root: $0.path)
            }) {
                return here
            }
        }
        return nil
    }

    /// Two different situations, and they need different sentences: a
    /// repository whose only checkout is the one you are in has somewhere to
    /// go once you make it, and a list that has not arrived yet has not said
    /// anything.
    private func emptyMessage(for root: String) -> String {
        center.list(forRoot: root).isEmpty
            ? "Reading this repository's worktrees…"
            : "This is the only worktree. Create one to work on another branch in parallel."
    }

    private func name(of worktree: GitWorktree) -> String {
        if let branch = worktree.branch { return branch }
        if worktree.isDetached { return "detached" }
        return (worktree.path as NSString).lastPathComponent
    }

    private func occupantCount(_ worktree: GitWorktree) -> Int {
        terminalPwds.count { GitWorktreeMembership.contains(pwd: $0, root: worktree.path) }
    }

    // MARK: Confirming

    private func confirm(_ target: GitWorktree) -> some View {
        WorktreeMigrationConfirm(
            targetName: name(of: target),
            sourceName: currentWorktree.map(name(of:)) ?? "the current worktree",
            staying: WorktreeDocumentMigration.staying(in: plan),
            onView: { path in
                leaving { onViewFile(path) }
            },
            save: { path in editorCenter.save(path) },
            onContinue: {
                leaving { onMigrate(target, plan) }
            },
            onCancel: {
                confirming = nil
                plan = []
            }
        )
    }

    /// Pointing at a worktree either goes there or asks first.
    ///
    /// Asking only when there is something to ask about is what keeps this
    /// one click in the ordinary case — nothing open, or everything open
    /// clean and present on both sides. A dialog that appears every time to
    /// say "nothing to worry about" is one people learn to dismiss without
    /// reading, which is the opposite of what it is for.
    private func choose(_ worktree: GitWorktree) {
        guard action == .migrate else {
            leaving { onNewTerminal(worktree.path) }
            return
        }

        let source = currentWorktree?.path ?? currentPath ?? ""
        let outcomes = editorCenter.migrationPlan(from: source, to: worktree.path)

        guard !WorktreeDocumentMigration.staying(in: outcomes).isEmpty else {
            leaving { onMigrate(worktree, outcomes) }
            return
        }

        plan = outcomes
        confirming = worktree
    }

    /// Closes this popover, then acts — one runloop apart.
    ///
    /// The gap is what makes "New Worktree…" work. SwiftUI presents one
    /// thing at a time per presenter, and asking for a sheet in the same
    /// pass that dismisses the popover it was asked from silently presents
    /// nothing: the create sheet simply never appeared, which reads as a
    /// menu item that does nothing. Every action here goes through it, so
    /// the one that needs the gap cannot be the one that forgets it.
    private func leaving(_ act: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.async(execute: act)
    }

    private func refreshPlan() {
        guard let target = confirming else { return }
        let source = currentWorktree?.path ?? currentPath ?? ""
        plan = editorCenter.migrationPlan(from: source, to: target.path)
    }
}

/// One repository's worktrees as the chooser lists them.
struct WorktreeChooserSection: Equatable {
    let root: String
    let worktrees: [GitWorktree]

    /// Whether this family's list has arrived at all. A collapsed section
    /// deliberately has none — see `WorktreeScope.polled` — and that is not
    /// the same fact as a section a query emptied.
    let isListed: Bool
}

/// Which worktrees a typed query leaves the chooser.
///
/// The match itself is `BranchFilter`'s, asked one name at a time rather than
/// restated here. The Git panel's pickers and this popover are one gesture
/// over two kinds of list, and a second definition of what a query means is
/// how they would come to disagree about `gamma-310`. Asking also carries the
/// parts that are easy to lose: a query of nothing but spaces is no query,
/// and an absent one keeps everything in the caller's order.
enum WorktreeChooserFilter {
    /// - Parameter name: what the row shows — a branch, or a folder for a
    ///   detached checkout. Matching anything else would narrow a list by
    ///   text the reader cannot see.
    static func matches(
        _ worktrees: [GitWorktree],
        query: String,
        name: (GitWorktree) -> String
    ) -> [GitWorktree] {
        worktrees.filter { keeps(name($0), query: query) }
    }

    /// Every section, with the query applied inside each, in the order they
    /// arrived.
    ///
    /// A section goes away heading and all once nothing in it matches: a
    /// heading over nothing is a row the reader has to read to learn it is
    /// empty, and a workspace of twenty repositories would draw nineteen of
    /// them.
    ///
    /// Two kinds of section survive an empty result. One whose repository the
    /// query names, because typing a repository is a way of asking for all of
    /// it — so it comes back whole rather than narrowed. And one whose list
    /// has not arrived, because most of a workspace's sections have
    /// deliberately never been listed, and hiding them all would make one
    /// letter look as though it had found nothing.
    static func sections(
        _ sections: [WorktreeChooserSection],
        query: String,
        name: (GitWorktree) -> String
    ) -> [WorktreeChooserSection] {
        sections.compactMap { section in
            if keeps((section.root as NSString).lastPathComponent, query: query) {
                return section
            }

            let kept = matches(section.worktrees, query: query, name: name)
            guard kept.isEmpty else {
                return WorktreeChooserSection(
                    root: section.root,
                    worktrees: kept,
                    isListed: section.isListed)
            }

            return section.isListed ? nil : section
        }
    }

    private static func keeps(_ name: String, query: String) -> Bool {
        !BranchFilter.matches([name], query: query).isEmpty
    }
}

/// A row that highlights on hover, the way a menu item does. `.plain` alone
/// gives no feedback at all, and a list of things to point at with no
/// pointing feedback reads as a list of labels.
///
/// The hover state lives in a nested `View`, not on the style. A
/// `ButtonStyle` is not a `View`, so SwiftUI installs no `@State` storage
/// for it: declaring it there compiles, draws correctly on the first pass,
/// and then stops drawing the label at all once anything makes the style's
/// body re-evaluate. Which is how this was found — the chooser rendered its
/// rows when the worktree list was already cached and rendered two
/// invisible rows when the list arrived a moment after the popover opened.
private struct WorktreePopoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration

        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(
                            configuration.isPressed ? 0.16 : (isHovered ? 0.09 : 0)))
                )
                .onHover { isHovered = $0 }
        }
    }
}
