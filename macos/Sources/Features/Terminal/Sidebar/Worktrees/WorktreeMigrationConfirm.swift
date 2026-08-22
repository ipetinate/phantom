import SwiftUI

/// What the reader is told, and asked, before a terminal changes worktrees
/// with files open.
///
/// Inside the popover rather than as a second modal on top of it. Two
/// ceremonies for one gesture is where a flow turns into paperwork, and this
/// one has to stay cheap enough to use several times an hour.
///
/// There is no discard. Every row here either comes along or stays behind
/// intact — the reader's edits are never a thing this view can throw away,
/// which is what makes pressing Continue safe without reading the list.
struct WorktreeMigrationConfirm: View {
    /// Where the terminal is going, named the way the reader chose it.
    let targetName: String

    /// Where the unsaved files stay. Named, not called "here", because after
    /// the switch it will not be here any more.
    let sourceName: String

    /// The `stayDirty` and `stayMissing` half of the plan, in tab order.
    let staying: [WorktreeDocumentMigration.Outcome]

    /// Opens the file and **cancels the switch**.
    ///
    /// Holding a pending switch while the reader goes off to read a file is
    /// state that rots: they may save it, close it, edit three others, and
    /// come back to a popover promising something about a situation that has
    /// changed underneath it.
    let onView: (String) -> Void

    /// Saves one file. Returns nil on success, or a sentence to show on that
    /// row — a read-only file and a full disk are both things that happen at
    /// exactly this moment, and an alert on top of a popover would cover the
    /// list it is talking about.
    let save: (String) -> String?

    let onContinue: () -> Void
    let onCancel: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared

    @State private var failures: [String: String] = [:]

    /// Rows that a save would change. `stayMissing` is not one of them:
    /// saving cannot create the file at the destination, because the
    /// destination is what it does not have.
    private var savable: [String] {
        staying.compactMap {
            guard case .stayDirty(let path) = $0 else { return nil }
            return path
        }
    }

    /// Five rows, then scroll. A popover that grows with the number of open
    /// files stops being a popover somewhere around eight.
    private var listMaximumHeight: CGFloat { 5 * 26 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            /// Two sentences for two situations, and the second is reachable
            /// from the first: saving every row empties the list, and the
            /// rule about what stays behind then describes nothing. Leaving
            /// it up over an empty list would read as a warning with its
            /// subject missing.
            Text(staying.isEmpty
                ? "Everything open comes with you."
                : "Saved files come with you; unsaved ones stay in \(sourceName).")
                .font(palette.font(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !staying.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(staying, id: \.path) { outcome in
                            row(outcome)
                        }
                    }
                }
                .frame(maxHeight: listMaximumHeight)
                .scrollIndicators(.automatic)
            }

            footer
        }
        .padding(12)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Moving to \(targetName)")
                .font(palette.font(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            /// Only worth its width past the first one. With a single dirty
            /// file, "Save all" and the row's own "Save" are two buttons for
            /// one action.
            if savable.count > 1 {
                Button("Save All") { for path in savable { attemptSave(path) } }
                    .buttonStyle(.link)
                    .font(palette.font(size: 10.5))
            }
        }
    }

    @ViewBuilder
    private func row(_ outcome: WorktreeDocumentMigration.Outcome) -> some View {
        let path = outcome.path

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                marker(outcome)

                Text((path as NSString).lastPathComponent)
                    .font(palette.font(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)

                Spacer(minLength: 4)

                switch outcome {
                case .stayDirty:
                    Button("View") { onView(path) }
                        .buttonStyle(.link)
                        .font(palette.font(size: 10.5))

                    Button("Save") { attemptSave(path) }
                        .buttonStyle(.link)
                        .font(palette.font(size: 10.5))

                case .stayMissing:
                    /// Named rather than actioned. There is nothing to press:
                    /// the file is not in the worktree we are going to, and
                    /// saving it there would create one the reader never
                    /// wrote.
                    Text("only on \(sourceName)")
                        .font(palette.font(size: 10))
                        .foregroundStyle(.secondary)

                case .migrate, .unrelated:
                    EmptyView()
                }
            }

            if let failure = failures[path] {
                Text(failure)
                    .font(palette.font(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// Two states, told apart at a glance: something to decide about, and
    /// something merely being reported.
    @ViewBuilder
    private func marker(_ outcome: WorktreeDocumentMigration.Outcome) -> some View {
        switch outcome {
        case .stayDirty:
            Circle().fill(.yellow).frame(width: 5, height: 5).frame(width: 12)
        case .stayMissing:
            Image(systemName: "minus.circle")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 12)
        case .migrate, .unrelated:
            Color.clear.frame(width: 12, height: 1)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Continue", action: onContinue)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// A saved file stops being a reason to stay, and its row leaves the
    /// list on its own: the owner of this view recomputes the plan whenever
    /// the editor's tabs change, and a clean file is no longer part of the
    /// staying half.
    ///
    /// That is the whole meaning of the button. "Saved files come with you"
    /// is printed at the top of this view, so pressing Save here has to
    /// actually change where the file ends up — anything else would make the
    /// sentence a lie about the button directly beneath it.
    private func attemptSave(_ path: String) {
        if let failure = save(path) {
            failures[path] = failure
        } else {
            failures.removeValue(forKey: path)
        }
    }
}
