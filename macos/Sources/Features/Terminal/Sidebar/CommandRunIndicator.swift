import SwiftUI

/// The trailing mark a row shows for a plain command: the spinner and the dot
/// the agent states already draw, at the same sizes.
///
/// Deliberately not a new shape. The reader asked for the indicator they
/// already know, on a `brew install` — a second visual language for "this tab
/// is busy" would make the row say two things where it means one.
///
/// Its own view rather than two more cases in the row's `statusIndicator`,
/// which switches on `agentState`: this is not one of those, and it has to be
/// drawn from the branch where there is no agent state at all.
struct CommandRunIndicator: View {
    let mark: CommandRunMark

    @ObservedObject private var themePalette: ThemePalette = .shared

    var body: some View {
        switch mark {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
                .help("Running a command")
        case .finished:
            Circle()
                .fill(themePalette.accent ?? .accentColor)
                .frame(width: 8, height: 8)
                .help("A command finished here")
        }
    }
}
