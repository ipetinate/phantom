import Foundation

/// What pressing Finish is about to do, worked out before anything is written.
///
/// Pure: it reads state it is handed and answers with a list. No installer, no
/// `UserDefaults`, no view — which is what lets the sentence under the
/// checkboxes and the work itself come from the same place instead of drifting
/// into describing different things.
enum WelcomeSetupPlan {
    /// The three checkboxes, and the order the work happens in.
    ///
    /// Hooks before the MCP entry before the buttons, from slowest and most
    /// consequential to cheapest: the first two write into files that belong to
    /// somebody else's app, the last is this app's own preferences.
    enum Step: String, CaseIterable, Equatable, Sendable {
        case hooks
        case mcp
        case buttons

        var title: String {
            switch self {
            case .hooks: return "Hooks"
            case .mcp: return "MCP server"
            case .buttons: return "Sidebar buttons"
            }
        }

        /// One line, in the reader's terms, about what this writes.
        /// The name inside a sentence, which is not the title with its case
        /// dropped: lowercasing `MCP server` gives `mcp server`, which is the
        /// one thing in this panel a reader would recognise as wrong.
        var summaryName: String {
            switch self {
            case .hooks: return "hooks"
            case .mcp: return "the MCP server"
            case .buttons: return "the sidebar buttons"
            }
        }

        var detail: String {
            switch self {
            case .hooks:
                return "Tab shows what the agent is doing — working, waiting on you, done."
            case .mcp:
                return "Lets the agent drive this window: open files, read terminals, work worktrees."
            case .buttons:
                return "Puts that agent's button on the sidebar, the group header and the tab row."
            }
        }
    }

    /// One thing that will be done to one agent.
    struct Item: Equatable, Identifiable, Sendable {
        let agent: CodingAgent
        let step: Step

        var id: String { "\(agent.rawValue).\(step.rawValue)" }
    }

    /// What the state of one agent is, as the panel found it.
    struct AgentState: Equatable, Sendable {
        var hooksInstalled: Bool
        var mcpRegistered: Bool
        var buttonsShown: Bool

        /// Nothing left for the panel to do. The card says so and offers no
        /// action, which is the whole answer for a reader who set this machine
        /// up months ago and is only seeing the window because it is new.
        var isComplete: Bool { hooksInstalled && mcpRegistered && buttonsShown }

        func has(_ step: Step) -> Bool {
            switch step {
            case .hooks: return hooksInstalled
            case .mcp: return mcpRegistered
            case .buttons: return buttonsShown
            }
        }
    }

    /// The work, in order, for the agents that are switched on.
    ///
    /// Already-done work is left out rather than repeated. Every installer is
    /// idempotent, so repeating it would be harmless — but the list is also
    /// what the reader is shown, and "install hooks for Claude Code" beside an
    /// agent that has had them since March is a sentence that makes the panel
    /// less trustworthy, not more.
    static func items(
        chosen: [CodingAgent],
        steps: Set<Step>,
        state: [CodingAgent: AgentState]
    ) -> [Item] {
        var work: [Item] = []
        for step in Step.allCases where steps.contains(step) {
            for agent in chosen {
                let current = state[agent] ?? AgentState(
                    hooksInstalled: false, mcpRegistered: false, buttonsShown: false)
                guard !current.has(step) else { continue }
                work.append(Item(agent: agent, step: step))
            }
        }
        return work
    }

    /// The line under the checkboxes. It names what will happen and to whom,
    /// because a switch and three ticks are not a sentence anybody can check.
    static func summary(
        chosen: [CodingAgent],
        steps: Set<Step>,
        state: [CodingAgent: AgentState]
    ) -> String {
        guard !chosen.isEmpty else {
            return "Nothing selected. Finish closes this window and changes nothing."
        }
        guard !steps.isEmpty else {
            return "Nothing ticked. Finish closes this window and changes nothing."
        }

        let work = items(chosen: chosen, steps: steps, state: state)
        guard !work.isEmpty else {
            return "\(names(of: chosen)) already set up. Finish just closes this window."
        }

        let stepNames = Step.allCases
            .filter { step in work.contains { $0.step == step } }
            .map(\.summaryName)

        /// The agents with something left to do, not everything switched on.
        /// An agent that is already set up stays switched on — it is a true
        /// statement about the machine — but naming it here would promise work
        /// that is not going to happen.
        let touched = chosen.filter { agent in work.contains { $0.agent == agent } }

        return "Finish sets up \(list(stepNames)) for \(names(of: touched)). "
            + "Every one of them is reversible in Settings."
    }

    private static func names(of agents: [CodingAgent]) -> String {
        list(agents.map(\.displayName))
    }

    /// "a", "a and b", "a, b and c" — the shape a sentence needs, not a
    /// comma-joined array.
    private static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        }
    }
}
