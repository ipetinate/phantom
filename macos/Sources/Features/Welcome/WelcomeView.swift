import AppKit
import SwiftUI

/// The welcome window's three steps.
///
/// Hero, then what the app does, then the agents — in that order because the
/// last one is the only one that writes anything, and a reader who has just met
/// this app should know what an agent hook *is* before being offered six of
/// them. It is also the only step with a way past it that does nothing: Skip.
struct WelcomeView: View {
    let close: () -> Void

    private enum Step: Int, CaseIterable {
        case hero
        case basics
        case agents
    }

    @State private var step: Step = .hero
    @Namespace private var hero

    @ObservedObject private var availability = AgentAvailability.shared
    @ObservedObject private var palette: ThemePalette = .shared

    @State private var hooks: [CodingAgent: Bool] = [:]
    @State private var registrations: [CodingAgent: Bool] = [:]
    @State private var chosen: Set<CodingAgent> = []
    @State private var steps: Set<WelcomeSetupPlan.Step> = Set(WelcomeSetupPlan.Step.allCases)

    /// One install run per agent, made when that agent's first install starts.
    @State private var runs: [CodingAgent: PackageInstallRun] = [:]

    /// What Finish could not do. Non-empty keeps the window open: a failure
    /// behind a window that has already closed is a failure nobody sees.
    @State private var failures: [String] = []

    /// Whether the switches have been seeded from the machine. Once, so a probe
    /// answering later never moves a switch the reader has touched.
    @State private var didSeed = false

    @State private var showsAtLaunch = WelcomeShownRecord.showsAtLaunch

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if step == .hero {
                heroStep
            } else {
                header
                Divider()
                content
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            availability.refresh()
            availability.startWatchingPath()
            refreshAgentState()
        }
        .onChange(of: availability.hasProbed) { _ in seedChoicesIfNeeded() }
    }

    // MARK: Step one

    private var heroStep: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            ghosttyIconImage()
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 128)
                .matchedGeometryEffect(id: "mark", in: hero)

            VStack(spacing: 8) {
                Text(Phantom.name)
                    .font(.system(size: 30, weight: .semibold))
                    .matchedGeometryEffect(id: "title", in: hero)

                Text("""
                    A terminal that keeps your agents, your worktrees and your \
                    diffs in one window.
                    """)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
    }

    /// What the hero becomes: the same two things, small, in the corner.
    private var header: some View {
        HStack(spacing: 10) {
            ghosttyIconImage()
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 28)
                .matchedGeometryEffect(id: "mark", in: hero)

            Text(Phantom.name)
                .font(.system(size: 15, weight: .semibold))
                .matchedGeometryEffect(id: "title", in: hero)

            Text(step == .basics ? "What this app does" : "Your agents")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Steps two and three

    @ViewBuilder
    private var content: some View {
        switch step {
        case .hero:
            EmptyView()
        case .basics:
            WelcomeBasicsStep()
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        case .agents:
            agentsStep
        }
    }

    private var agentsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("""
                    Turn on the agents you use. Phantom installs that agent's \
                    hooks, registers its MCP server and shows its buttons — \
                    each of them reversible in Settings.
                    """)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(CodingAgent.allCases, id: \.self) { agent in
                        card(for: agent)
                    }
                }

                Divider().padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(WelcomeSetupPlan.Step.allCases, id: \.self) { setupStep in
                        Toggle(isOn: binding(for: setupStep)) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(setupStep.title)
                                    .font(.system(size: 12))
                                Text(setupStep.detail)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(setupStep.detail)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }

                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(AgentInstallPlan.signInNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if !failures.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(failures, id: \.self) { failure in
                            Text(failure)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func card(for agent: CodingAgent) -> some View {
        WelcomeAgentCard(
            agent: agent,
            state: state(of: agent),
            path: availability.path(for: agent),
            hasProbed: availability.hasProbed,
            isChosen: chosen.contains(agent),
            onChoose: { wanted in
                if wanted { chosen.insert(agent) } else { chosen.remove(agent) }
            },
            install: AgentInstallPlan.command(
                for: agent, managers: availability.availableManagers),
            documentation: AgentInstallPlan.documentation[agent],
            onInstall: { command in start(command, for: agent) },
            run: run(for: agent))
    }

    // MARK: The bottom bar

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Show at startup", isOn: Binding(
                get: { showsAtLaunch },
                set: { value in
                    showsAtLaunch = value
                    WelcomeShownRecord.setShowsAtLaunch(value)
                }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Also available under Help, and in Settings → General.")

            Spacer(minLength: 8)

            dots

            Spacer(minLength: 8)

            buttons
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(Step.allCases, id: \.rawValue) { each in
                Circle()
                    .fill(each == step ? accent : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch step {
        case .hero:
            Button("Start") { advance(to: .basics) }
                .keyboardShortcut(.defaultAction)
        case .basics:
            Button("Next") { advance(to: .agents) }
                .keyboardShortcut(.defaultAction)
        case .agents:
            HStack(spacing: 8) {
                Button("Skip", action: close)
                Button("Finish", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Doing it

    private func advance(to next: Step) {
        withAnimation(.easeInOut(duration: 0.28)) { step = next }
    }

    /// Applies what the summary said, one action at a time, and reports each
    /// one that failed by name.
    ///
    /// The window closes only when everything worked. Every installer here is
    /// idempotent, so pressing Finish again after a failure is the repair.
    private func finish() {
        let work = WelcomeSetupPlan.items(
            chosen: orderedChoice, steps: steps, state: agentState)

        var failed: [String] = []
        for item in work {
            guard let reason = perform(item) else { continue }
            failed.append(reason)
        }

        refreshAgentState()
        failures = failed
        if failed.isEmpty { close() }
    }

    /// Nil when it worked, otherwise the sentence to show.
    private func perform(_ item: WelcomeSetupPlan.Item) -> String? {
        switch item.step {
        case .hooks:
            guard let agent = AgentHooksRegistration.agents.first(where: { $0.id == item.agent })
            else { return nil }
            guard !agent.install() else { return nil }
            return "\(agent.name): hooks failed\(agent.lastError().map { " — \($0)" } ?? "")"

        case .mcp:
            guard let agent = MCPServerRegistration.agents.first(where: { $0.id == item.agent })
            else { return nil }
            guard !agent.register() else { return nil }
            return "\(agent.name): MCP entry failed\(agent.lastError().map { " — \($0)" } ?? "")"

        case .buttons:
            for surface in AgentButtonSurface.allCases {
                UserDefaults.standard.set(
                    true, forKey: AgentButtonDefaults.key(surface, item.agent))
            }
            return nil
        }
    }

    private func start(_ command: AgentInstallCommand, for agent: CodingAgent) {
        run(for: agent).run(command.command) { worked in
            guard worked else { return }
            availability.noteAvailabilityChanged()
        }
    }

    // MARK: State

    private var agentState: [CodingAgent: WelcomeSetupPlan.AgentState] {
        Dictionary(uniqueKeysWithValues: CodingAgent.allCases.map { ($0, state(of: $0)) })
    }

    private func state(of agent: CodingAgent) -> WelcomeSetupPlan.AgentState {
        WelcomeSetupPlan.AgentState(
            hooksInstalled: hooks[agent] ?? false,
            mcpRegistered: registrations[agent] ?? false,
            buttonsShown: AgentButtonSurface.allCases.allSatisfy { surface in
                UserDefaults.standard.object(
                    forKey: AgentButtonDefaults.key(surface, agent)) as? Bool
                    ?? AgentButtonDefaults.isShown(agent)
            })
    }

    /// In the enum's order rather than the set's, so the sentence under the
    /// checkboxes reads the same way twice.
    private var orderedChoice: [CodingAgent] {
        CodingAgent.allCases.filter { chosen.contains($0) }
    }

    private var summary: String {
        WelcomeSetupPlan.summary(chosen: orderedChoice, steps: steps, state: agentState)
    }

    private func refreshAgentState() {
        hooks = AgentHooksRegistration.status()
        registrations = MCPServerRegistration.status()
    }

    /// The agents on this machine start switched on, once the probe has said
    /// which those are — and only once, so an install finishing later never
    /// moves a switch somebody has since touched.
    private func seedChoicesIfNeeded() {
        guard availability.hasProbed, !didSeed else { return }
        didSeed = true
        chosen = Set(CodingAgent.allCases.filter { availability.isInstalled($0) })
    }

    private func binding(for setupStep: WelcomeSetupPlan.Step) -> Binding<Bool> {
        Binding(
            get: { steps.contains(setupStep) },
            set: { wanted in
                if wanted { steps.insert(setupStep) } else { steps.remove(setupStep) }
            })
    }

    private func run(for agent: CodingAgent) -> PackageInstallRun {
        if let existing = runs[agent] { return existing }
        let made = PackageInstallRun()
        runs[agent] = made
        return made
    }
}
