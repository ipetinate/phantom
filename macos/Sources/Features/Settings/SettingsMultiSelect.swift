import SwiftUI

/// Show/hide choices that belong together, folded into one row.
///
/// Written for the sidebar pane, where twenty switches with near-identical
/// labels — "Show Working Directory", "Show Git Branch", "Show Open Pull
/// Request", "Show Dev Server Port" — gave a wall with no shape. The reaction
/// that prompted it was *"muita coisa, nem li"*, which is the correct reaction
/// to eight consecutive switches whose labels differ in one noun.
///
/// The rule: **four or more homogeneous show/hide items become one row; three
/// or fewer stay switches.** Below four a menu costs a click and saves no
/// height.
///
/// The summary names what is on rather than counting it. "3 of 6" is stable
/// and answers the wrong question — you open Settings to find out whether the
/// branch is showing, not how many chips exist.
struct SettingsMultiSelect: View {
    struct Option: Identifiable {
        let id: String

        /// As it reads inside the menu, where there is room.
        let title: String

        /// As it reads in the summary, where several share a line. Defaults
        /// to the title.
        var short: String?

        let isOn: Binding<Bool>
    }

    let title: String
    let options: [Option]

    /// What the summary says with nothing selected. "None" is right for a
    /// list of chips and wrong for one of buttons, where "Hidden" reads
    /// better.
    var emptyLabel: String = "None"

    private var chosen: [Option] {
        options.filter(\.isOn.wrappedValue)
    }

    private var summary: String {
        guard !chosen.isEmpty else { return emptyLabel }
        guard chosen.count < options.count else { return "All" }
        return chosen.map { $0.short ?? $0.title }.joined(separator: ", ")
    }

    var body: some View {
        LabeledContent(title) {
            Menu {
                ForEach(options) { option in
                    Toggle(option.title, isOn: option.isOn)
                }
            } label: {
                Text(summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            /// Fixed width so the control does not resize as items are
            /// toggled — a row that jumps while you are reading it is worse
            /// than one that truncates.
            .frame(width: 220, alignment: .trailing)
        }
    }
}
