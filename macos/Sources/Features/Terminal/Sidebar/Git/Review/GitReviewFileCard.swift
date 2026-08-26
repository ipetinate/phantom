import AppKit
import SwiftUI

/// One changed file in the review, and its diff when the reader asks.
///
/// **Closed by default, and the diff is not loaded until it opens.** A branch
/// that touches two hundred files is the case that decides this: loading every
/// diff to draw a list nobody has scrolled to is the slow version of this
/// screen, and the accordion is what makes "show me the list" and "show me
/// this file" two different costs.
struct GitReviewFileCard: View {
    let file: GitReviewFile
    let scope: GitReviewScope
    let theme: CodeTheme
    let font: NSFont
    /// What the branch is compared against, from the header that resolved it.
    ///
    /// Passed down rather than read from the centre, because the centre is
    /// `@MainActor` and the load runs off it — and because one value handed
    /// down cannot disagree with the header the way two lookups can.
    let target: String

    let isExpanded: Bool
    let onToggle: () -> Void
    let onOpenFile: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var icons: FileIconProvider = .shared

    @State private var outcome: GitDiffOutcome?
    @State private var lastCommit: GitReviewCommit?
    @StateObject private var splitModel = SplitPaneModel()

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if isExpanded {
                Divider()
                body(for: outcome)
                    .frame(minHeight: 160, maxHeight: 460)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1))
        .task(id: taskKey) { await loadIfNeeded() }
    }

    /// Reloads when the file, the scope or the open state changes — and not
    /// when anything else does. Being keyed on `isExpanded` is what defers the
    /// diff until the card opens.
    private var taskKey: String {
        "\(scope.id)\u{1}\(file.path)\u{1}\(target)\u{1}\(isExpanded)"
    }

    // MARK: The card's own row

    @ViewBuilder
    private var headerRow: some View {
        Button(action: onToggle) {
            HStack(spacing: 7) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)

                FileIconView(icon: icons.icon(forFile: file.name), size: 13)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(file.name)
                            .font(palette.font(size: 11, weight: .medium))
                            .lineLimit(1)

                        Text(file.status.badge)
                            .font(palette.font(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Text(details)
                        .font(palette.font(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 6)

                if let added = file.addedLines, let removed = file.removedLines {
                    Text(verbatim: "+\(added)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(verbatim: "\u{2212}\(removed)")
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

                SidebarIconButton(help: "Open File", action: onOpenFile) {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The line under the name: where the file is, and who last touched it.
    ///
    /// The directory first, because two files with the same name in a module
    /// tree are told apart by nothing else. The commit is the one that will
    /// land the change — the *last* one to touch it, which is what a pull
    /// request's file list credits — and on a single commit's review it is
    /// that commit, which is why the scope decides rather than the loader.
    private var details: String {
        var parts: [String] = []
        if !file.directory.isEmpty { parts.append(file.directory) }
        if let extensionName = fileExtension { parts.append(extensionName) }
        if let commit = lastCommit {
            parts.append("\(commit.shortSha) \u{2022} \(commit.subject)")
        }
        return parts.joined(separator: "  \u{2022}  ")
    }

    private var fileExtension: String? {
        let suffix = (file.name as NSString).pathExtension
        return suffix.isEmpty ? nil : suffix.uppercased()
    }

    // MARK: The diff

    @ViewBuilder
    private func body(for outcome: GitDiffOutcome?) -> some View {
        switch outcome {
        case .none:
            note("Reading the diff\u{2026}")
        case .diff(let document):
            GitReviewFileDiff(
                document: document,
                theme: theme,
                font: font,
                model: splitModel)
        case .unchanged:
            note("Git reports no change on this side.")
        case .conflicted:
            note("This file has conflicts. Resolve them to see a diff.")
        case .tooLarge(let bytes):
            note("Bigger than the reviewer will draw (\(bytes) bytes).")
        case .failed(let failure):
            note(failure.title)
        }
    }

    @ViewBuilder
    private func note(_ message: String) -> some View {
        Text(message)
            .font(palette.font(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(20)
    }

    // MARK: Loading

    private func loadIfNeeded() async {
        guard isExpanded else { return }
        guard outcome == nil else { return }

        let scope = scope
        let path = file.path
        let previous = file.previousPath
        let target = target

        let loaded = await Task.detached(priority: .userInitiated) {
            GitReviewFileDiffLoader.load(
                path: path, previousPath: previous, scope: scope, target: target)
        }.value

        outcome = loaded.outcome
        lastCommit = loaded.commit
    }
}
