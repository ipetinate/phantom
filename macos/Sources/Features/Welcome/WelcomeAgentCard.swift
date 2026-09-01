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

    /// One of the two plain steps.
    ///
    /// A real `Toggle` in the checkbox style rather than a symbol somebody has
    /// to discover is tappable. The first version drew its own square and text
    /// and relied on a tap gesture over the row: it looked like a status line,
    /// which is what it had been one version earlier — so nobody read it as
    /// something to click.
    ///
    /// Already done is a green tick and no control at all. This panel sets up;
    /// taking a hook back out is Settings' job, and a checkbox that could
    /// uninstall would make Finish a destructive button.
    @ViewBuilder
    private func choice(_ step: WelcomeSetupPlan.Step) -> some View {
        if state.has(step) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                Text(step.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .help("Already set up — remove it in Settings")
        } else {
            Toggle(step.title, isOn: Binding(
                get: { selection?.steps.contains(step) ?? false },
                set: { wanted in onSelect(step, wanted) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .disabled(!isChosen)
                .help(step.detail)
        }
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
                .foregroundStyle(state.has(.buttons) ? .secondary : .primary)

            ForEach(AgentButtonSurface.allCases, id: \.self) { surface in
                place(surface)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func place(_ surface: AgentButtonSurface) -> some View {
        if state.buttonsShown.contains(surface) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text(surface.shortName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .help("Already shown \(surface.placeName)")
        } else {
            Toggle(surface.shortName, isOn: Binding(
                get: { selection?.surfaces.contains(surface) ?? false },
                set: { wanted in onSelectSurface(surface, wanted) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .disabled(!isChosen)
                .help("Show it \(surface.placeName)")
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
