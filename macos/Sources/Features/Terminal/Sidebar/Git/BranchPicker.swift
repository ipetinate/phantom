import AppKit
import SwiftUI

/// Choosing one branch out of however many the repository has.
///
/// A menu was the wrong shape for this and the size of the list is what
/// showed it: a repository with a few hundred branches drew a menu the full
/// height of the screen, with no way in it to say which branch you wanted
/// except to read every one. `NSMenu` cannot hold a text field, so the fix is
/// not a modifier — it is this, a popover, which can.
///
/// What it owes the reader: type to narrow, Return to take the first match,
/// and a height that stops at half the screen so the list scrolls instead of
/// growing past the window it belongs to.
struct BranchPicker: View {
    /// The branches, in the order the caller wants them read. Nothing here
    /// re-sorts: `GitCenter` hands them over newest-committed first and the
    /// review centre puts the likely targets at the top, and both of those
    /// orders carry information this view does not have.
    let branches: [String]

    /// The one already chosen, ticked in the list. Nil when the caller is
    /// starting a branch rather than changing one.
    var current: String?

    /// Offered rather than performed, and the wording says so: a fetch is the
    /// network, and a picker that reached for it on open would stall on every
    /// use for a list most readers do not need refreshed.
    var onRefresh: (() -> Void)?

    let onPick: (String) -> Void

    /// Closed by this view when a branch is taken, because a popover that
    /// stays open after the choice reads as a choice that did not register.
    @Binding var isPresented: Bool

    @ObservedObject private var palette: ThemePalette = .shared

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    /// Half the screen, which is what the reader asked for, less the popover's
    /// own chrome: the search row, the divider and the arrow come out of the
    /// budget rather than being added to it.
    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(160, screen * 0.5 - 90)
    }

    /// Measured, because a `ScrollView` takes the whole height it is offered
    /// along its axis: without this, three branches would get the same
    /// half-screen popover as three hundred. The same idiom as
    /// `SidebarPullRequestList`.
    @State private var contentHeight: CGFloat?

    private var matches: [String] { BranchFilter.matches(branches, query: query) }

    var body: some View {
        VStack(spacing: 0) {
            search
            Divider()

            if matches.isEmpty {
                Text("No branch matches \u{201C}\(query)\u{201D}.")
                    .font(palette.captionFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                list
            }

            if let onRefresh {
                Divider()
                Button {
                    onRefresh()
                } label: {
                    Label("Refresh branches (fetch)", systemImage: "arrow.clockwise")
                        .font(palette.font(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .frame(width: 320)
        .onAppear { isSearchFocused = true }
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            /// Return takes the first match, so the whole gesture is type and
            /// press — which is the point of the field. Anything else would
            /// leave the reader typing to narrow and then reaching for the
            /// mouse to pick out of what is left.
            TextField("Search branches", text: $query)
                .textFieldStyle(.plain)
                .font(palette.font(size: 11))
                .focused($isSearchFocused)
                .onSubmit {
                    guard let first = matches.first else { return }
                    pick(first)
                }

            if !query.isEmpty {
                Text(verbatim: "\(matches.count)/\(branches.count)")
                    .font(palette.font(size: 10))
                    .foregroundStyle(.tertiary)

                Button {
                    query = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(matches, id: \.self) { branch in
                    row(branch)
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: BranchListHeightKey.self,
                        value: proxy.size.height
                    )
                }
            )
            .background(alignment: .top) { OverlayScrollers() }
        }
        .scrollIndicators(.automatic)
        .onPreferenceChange(BranchListHeightKey.self) { height in
            contentHeight = height
        }
        .frame(height: contentHeight.map { min($0, maxListHeight) })
    }

    private func row(_ branch: String) -> some View {
        Button {
            pick(branch)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(branch == current ? 1 : 0)

                Text(branch)
                    .font(palette.font(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(BranchRowStyle())
    }

    private func pick(_ branch: String) {
        onPick(branch)
        isPresented = false
    }
}

/// The hover a row in a list of branches gets, which is the one a menu item
/// would have given it.
private struct BranchRowStyle: ButtonStyle {
    @ObservedObject private var palette: ThemePalette = .shared
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                (palette.accent ?? .accentColor)
                    .opacity(configuration.isPressed ? 0.35 : (isHovered ? 0.22 : 0))
            )
            .onHover { isHovered = $0 }
    }
}

private struct BranchListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Which branches a typed query leaves.
///
/// Its own type because the answer is a decision, not a detail: a reader
/// typing `gamma-310` means the branch whose name ends that way, wherever the
/// name starts — `feat/gamma-310` and `origin/feat/gamma-310` both. Substring
/// matching is what gives them that; a prefix match would answer neither.
enum BranchFilter {
    /// The order is the caller's, always. `GitCenter` sorts by commit date and
    /// the review centre puts likely targets first, and re-ranking by how well
    /// a name matches would throw away information the reader is relying on to
    /// recognise their own branch.
    static func matches(_ branches: [String], query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return branches }
        return branches.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}
