import AppKit
import SwiftUI

/// One agent, in the last step: whether it is here, what is already set up for
/// it, and a switch saying whether Finish should set up the rest.
///
/// The card refuses to guess. Until the probe has answered it says so, rather
/// than offering to install something that may already be there — the rule the
/// language-server rows follow, and for the reason stated there.
struct WelcomeAgentCard: View {
    let agent: CodingAgent
    let state: WelcomeSetupPlan.AgentState

    /// Where the CLI was found, or nil when it is not on the `PATH`. The path
    /// itself is shown because `pi` and `agy` are short names and `PATH` cannot
    /// tell an agent from something else called that.
    let path: String?

    let hasProbed: Bool
    let isChosen: Bool
    let onChoose: (Bool) -> Void

    /// The install, when this app has a command for this agent and the machine
    /// has the manager it needs.
    let install: AgentInstallCommand?
    let documentation: URL?
    let onInstall: (AgentInstallCommand) -> Void

    /// The run for *this* card, when one is going.
    @ObservedObject var run: PackageInstallRun

    @ObservedObject private var palette: ThemePalette = .shared

    private var accent: Color { palette.accent ?? .accentColor }
    private var isInstalled: Bool { path != nil }

    /// Every card is this tall, whatever it has to say.
    ///
    /// The grid was ragged without it: an agent with three state lines made a
    /// tall card, one that is already set up made a short one, and a row took
    /// the height of its tallest cell — so six cards drew six sizes and two
    /// alignments. The layout below is therefore the *same shape* in all four
    /// states, with a header, a subtitle line and three body lines; what
    /// changes is what those lines say.
    static let height: CGFloat = 112

    /// The three lines under the rule, for every state. Fixed so the four
    /// states cannot each pick their own.
    private static let bodyLines = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider().opacity(0.4)
            body(for: bodyState)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isChosen ? accent.opacity(0.10) : Color.secondary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isChosen ? accent.opacity(0.45) : Color.secondary.opacity(0.16)))
    }

    /// Which of the four things a card can be saying.
    private enum BodyState {
        case checking
        case installing
        case missing
        case present
    }

    private var bodyState: BodyState {
        guard hasProbed else { return .checking }
        if run.isRunning { return .installing }
        return isInstalled ? .present : .missing
    }

    // MARK: The row across the top

    /// Name, then where it was found, then the switch. The subtitle line is
    /// always drawn — the path when there is one, the state when there is not
    /// — so the rule below sits at the same height on every card.
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentBrandMark(agent: agent, size: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 9.5, design: path == nil ? .default : .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path ?? subtitle)
            }

            Spacer(minLength: 4)

            /// Reserved whether or not there is a switch, so the name below it
            /// starts in the same place on every card. Nothing to choose while
            /// the CLI is missing or everything is already done: a switch that
            /// changes nothing makes the rest of the card less believable.
            Toggle("", isOn: Binding(get: { isChosen }, set: onChoose))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .opacity(canChoose ? 1 : 0)
                .allowsHitTesting(canChoose)
        }
    }

    private var canChoose: Bool {
        hasProbed && isInstalled && !state.isComplete
    }

    private var subtitle: String {
        if let path { return path }
        guard hasProbed else { return "Checking…" }
        return "Not installed"
    }

    // MARK: The three lines under the rule

    @ViewBuilder
    private func body(for state: BodyState) -> some View {
        switch state {
        case .checking:
            line { ProgressView().controlSize(.small) }

        case .present:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(WelcomeSetupPlan.Step.allCases, id: \.self) { step in
                    HStack(spacing: 5) {
                        Image(systemName: self.state.has(step) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 9))
                            .foregroundStyle(self.state.has(step) ? .green : Color.secondary)
                        Text(step.title)
                            .font(.system(size: 10.5))
                            .foregroundStyle(self.state.has(step) ? .secondary : .primary)
                            .lineLimit(1)
                    }
                }
            }

        case .installing:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let progress = run.progress {
                        ProgressView(value: progress).controlSize(.small).frame(width: 80)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("Installing…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                ForEach(run.recentOutput.suffix(2), id: \.self) { output in
                    Text(output)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

        case .missing:
            VStack(alignment: .leading, spacing: 3) {
                if let install {
                    HStack(spacing: 6) {
                        Button("Install") { onInstall(install) }
                            .controlSize(.small)
                        Text("with \(install.manager.displayName)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Text(install.command)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(install.command)
                } else if let documentation {
                    /// No command for this one, and that is a decision rather
                    /// than a gap — see `AgentInstallPlan.withoutInstallCommand`.
                    Link("How to install it", destination: documentation)
                        .font(.system(size: 11))
                }

                if let failure = run.failure {
                    Text(failure)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(failure)
                }
            }
        }
    }

    /// One body line's worth of height, for the states with less to say than
    /// the tallest one.
    private func line<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
