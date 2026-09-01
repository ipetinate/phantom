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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if hasProbed {
                if isInstalled {
                    readiness
                } else {
                    missing
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isChosen ? accent.opacity(0.10) : Color.secondary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isChosen ? accent.opacity(0.45) : Color.secondary.opacity(0.16)))
    }

    // MARK: The row across the top

    private var header: some View {
        HStack(spacing: 8) {
            AgentBrandMark(agent: agent, size: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName)
                    .font(.system(size: 12, weight: .semibold))

                if let path {
                    Text(path)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }

            Spacer(minLength: 4)

            /// Nothing to choose while the CLI is missing or everything is
            /// already done. A switch that changes nothing is a switch that
            /// makes the rest of the card less believable.
            if hasProbed, isInstalled, !state.isComplete {
                Toggle("", isOn: Binding(get: { isChosen }, set: onChoose))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
    }

    // MARK: Installed

    @ViewBuilder
    private var readiness: some View {
        if state.isComplete {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("Set up")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(WelcomeSetupPlan.Step.allCases, id: \.self) { step in
                    HStack(spacing: 5) {
                        Image(systemName: state.has(step) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 9))
                            .foregroundStyle(state.has(step) ? .green : Color.secondary)
                        Text(step.title)
                            .font(.system(size: 10.5))
                            .foregroundStyle(state.has(step) ? .secondary : .primary)
                    }
                }
            }
        }
    }

    // MARK: Not installed

    @ViewBuilder
    private var missing: some View {
        if run.isRunning {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let progress = run.progress {
                        ProgressView(value: progress).controlSize(.small).frame(width: 90)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("Installing…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                ForEach(run.recentOutput, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("Not installed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if let failure = run.failure {
                    Text(failure)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let install {
                    HStack(spacing: 8) {
                        Button("Install") { onInstall(install) }
                            .controlSize(.small)
                        Text(install.command)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(install.command)
                    }
                } else if let documentation {
                    /// No command for this one, and that is a decision rather
                    /// than a gap — see `AgentInstallPlan.withoutInstallCommand`.
                    Link("How to install it", destination: documentation)
                        .font(.system(size: 11))
                }
            }
        }
    }
}
