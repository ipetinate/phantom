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

    let commonRoot: String

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

    /// Opens the create sheet, which is where every question lives.
    let onNewWorktree: () -> Void

    /// Groups the terminals of one worktree together. Offered here because
    /// three terminals in one worktree usually *are* a group, and this is
    /// the moment the reader is thinking about that worktree.
    let onCreateGroup: (GitWorktree) -> Void

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

    var body: some View {
        Group {
            if let target = confirming {
                confirm(target)
            } else {
                chooser
            }
        }
        .onChange(of: editorCenter.tabs) { _ in refreshPlan() }
        /// Asked for again while this is open, which is what the panel does
        /// and for the same reason: `git worktree list` answers off the main
        /// thread, and a popover opened before it came back showed an empty
        /// chooser for as long as it stayed up. Every request inside the
        /// store's TTL is a no-op, so this costs nothing once the answer has
        /// landed.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            center.requestList(commonRoot: commonRoot)
        }
    }

    // MARK: Choosing

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(action == .migrate ? "Switch This Terminal To" : "Open a Terminal In")
                .font(palette.font(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

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
            ZStack(alignment: .topLeading) {
                if offered.isEmpty {
                    Text(emptyMessage)
                        .font(palette.font(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(offered) { worktree in
                                row(worktree)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                }
            }
            .frame(height: listHeight, alignment: .topLeading)

            Divider().padding(.vertical, 2)

            Button {
                leaving(onNewWorktree)
            } label: {
                Label("New Worktree…", systemImage: "plus")
                    .font(palette.font(size: 11))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            /// Set apart by a gap rather than by a second box: it is a
            /// different kind of action, but it is about the same thing the
            /// reader is already looking at.
            if let groupable = currentWorktree ?? offered.first {
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
        .padding(8)
        .frame(width: 260)
        /// Forced, because the answer may be a cached empty one: the store
        /// stamps its check time even when git failed, so an unforced
        /// request inside the TTL would decline to ask again and the chooser
        /// would stay empty on the strength of one bad answer.
        .onAppear { center.requestList(commonRoot: commonRoot, force: true) }
    }

    /// Room for three rows even when there are none yet, and never more
    /// than six — past that the list scrolls rather than the popover growing
    /// down the screen.
    private var listHeight: CGFloat {
        CGFloat(min(max(offered.count, 3), 6)) * 28
    }

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
    private var offered: [GitWorktree] {
        center.list(forRoot: commonRoot).filter { worktree in
            guard !worktree.isBare, !worktree.isPrunable else { return false }
            guard action == .migrate else { return true }
            return !GitWorktreeMembership.contains(pwd: currentPath, root: worktree.path)
        }
    }

    private var currentWorktree: GitWorktree? {
        center.list(forRoot: commonRoot).first {
            GitWorktreeMembership.contains(pwd: currentPath, root: $0.path)
        }
    }

    /// Two different situations, and they need different sentences: a
    /// repository whose only checkout is the one you are in has somewhere to
    /// go once you make it, and a list that has not arrived yet has not said
    /// anything.
    private var emptyMessage: String {
        center.list(forRoot: commonRoot).isEmpty
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
