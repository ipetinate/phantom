import SwiftUI

/// The trailing mark a row shows for a plain command: the spinner the agent
/// states already draw, a check when the command ended well, and the
/// triangle `failed` draws when it did not, at the same sizes.
///
/// Deliberately close to what the agent states draw. The reader asked for the
/// indicator they already know, on a `brew install` — a second visual language
/// for "this tab is busy" would make the row say two things where it means
/// one. The check is the one departure: a dot beside a triangle only said
/// "not running", and the tooltip on the triangle now says the exit code and
/// how long the command ran, so a red mark after a command that printed its
/// own success can be read rather than guessed at.
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
                .help(Text(verbatim: mark.tooltip))
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(themePalette.accent ?? .accentColor)
                .help(Text(verbatim: mark.tooltip))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .help(Text(verbatim: mark.tooltip))
        }
    }
}
