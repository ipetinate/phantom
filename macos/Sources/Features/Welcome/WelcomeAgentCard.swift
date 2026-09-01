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

    /// What the reader has asked for on this card. Nil while the agent is
    /// switched off — there is nothing to ask for until then.
    let selection: WelcomeSetupPlan.Selection?

    /// Ticking one of the card's own lines.
    let onSelect: (WelcomeSetupPlan.Step, Bool) -> Void

    /// Ticking one of the three places the button can go.
    let onSelectSurface: (AgentButtonSurface, Bool) -> Void

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
    static let height: CGFloat = 168

    /// The three lines under the rule, for every state. Fixed so the four
    /// states cannot each pick their own.
    private static let bodyLines = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider().opacity(0.4)
            body(for: bodyState)
            Spacer(minLength: 0)
        }
        .padding(12)
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
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 10.5, design: path == nil ? .default : .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path ?? subtitle)
            }

            Spacer(minLength: 4)

            /// One switch, on every card, meaning the same thing on all of
            /// them: whether this agent is set up here.
            ///
            /// It went through three shapes before this one — hidden where it
            /// would change nothing, then drawn and disabled, then replaced by
            /// a gear pointing at Settings — and each was the same mistake in a
            /// different coat: the reader wanted to change an agent that was
            /// already set up, and the panel kept sending them somewhere else.
            /// Off now asks Finish to take the agent's hooks, entry and buttons
            /// back out, through the same `uninstall` and `remove` the Settings
            /// panes call.
            Toggle("", isOn: Binding(get: { isChosen }, set: onChoose))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!canChoose)
                .help(switchHelp)
        }
    }

    private var canChoose: Bool {
        hasProbed && isInstalled && !state.isComplete
    }

    private var switchHelp: String {
        if !hasProbed { return "Looking for it on your PATH…" }
        if !isInstalled { return "Install \(agent.displayName) first" }
        return "Set \(agent.displayName) up when you press Finish"
    }

    private var manageHelp: String {
        "\(agent.displayName) is set up — change or remove it in Settings"
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
            VStack(alignment: .leading, spacing: 8) {
                choice(.hooks)
                choice(.mcp)
                places
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
                        .font(.system(size: 11.5))
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
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Text(install.command)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(install.command)
                } else if let documentation {
                    /// No command for this one, and that is a decision rather
                    /// than a gap — see `AgentInstallPlan.withoutInstallCommand`.
                    Link("How to install it", destination: documentation)
                        .font(.system(size: 12))
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

    /// One of the two plain steps, as a checkbox that means "this agent has
    /// this".
    ///
    /// The same box whether the agent has it or not, which is what makes
    /// unticking legible as *take it out* rather than as *do not add it*. The
    /// dot beside the label says the agent has it today: green when the tick
    /// agrees, orange when it does not — orange is the one that reads as "this
    /// is about to go".
    ///
    /// It read as a status line for two versions before this, then as a status
    /// line with a checkbox beside it for one more. It is a control.
    private func choice(_ step: WelcomeSetupPlan.Step) -> some View {
        let has = state.has(step)
        let wanted = selection?.steps.contains(step) ?? false

        return Toggle(isOn: Binding(get: { wanted }, set: { onSelect(step, $0) })) {
            HStack(spacing: 5) {
                Text(step.title)
                    .font(.system(size: 12))
                if has { dot(agrees: wanted) }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!canChoose)
        .help(helpFor(step, has: has, wanted: wanted))
    }

    private func helpFor(
        _ step: WelcomeSetupPlan.Step,
        has: Bool,
        wanted: Bool
    ) -> String {
        if has && !wanted { return "Set up now — Finish will remove it" }
        if has { return "Already set up" }
        return step.detail
    }

    /// Where the agent's button goes: three checkboxes, labelled, on one line.
    ///
    /// They were capsule chips, and a chip is a thing that looks pressed or not
    /// pressed rather than a thing you press — the reader could not tell they
    /// were controls at all. The label in front says what the three of them are
    /// for, which a row of bare place names does not.
    private var places: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Show its button")
                .font(.system(size: 12))

            ForEach(AgentButtonSurface.allCases, id: \.self) { surface in
                place(surface)
            }

            Spacer(minLength: 0)
        }
    }

    private func place(_ surface: AgentButtonSurface) -> some View {
        let shown = state.buttonsShown.contains(surface)
        let wanted = selection?.surfaces.contains(surface) ?? false

        return Toggle(isOn: Binding(
            get: { wanted },
            set: { onSelectSurface(surface, $0) })
        ) {
            HStack(spacing: 3) {
                Text(surface.shortName)
                    .font(.system(size: 11))
                if shown { dot(agrees: wanted) }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!canChoose)
        .help(shown && !wanted
            ? "Shown \(surface.placeName) — Finish will hide it"
            : "Show it \(surface.placeName)")
    }

    /// The mark that says "the agent has this today", and whether the tick
    /// beside it agrees.
    private func dot(agrees: Bool) -> some View {
        Circle()
            .fill(agrees ? Color.green : Color.orange)
            .frame(width: 5, height: 5)
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
