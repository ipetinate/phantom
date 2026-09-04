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

    /// Which way one item is going.
    enum Direction: String, Equatable, Sendable {
        case add
        case remove
    }

    /// One thing that will be done to one agent.
    struct Item: Equatable, Identifiable, Sendable {
        let agent: CodingAgent
        let step: Step

        /// Both directions, because the card is the agent's **state** and not a
        /// list of things to add. A reader who unticks the hooks is saying the
        /// hooks should not be there, and the panel that refused to hear that
        /// was a panel they had to leave, for Settings, to say it.
        var direction: Direction = .add

        /// For `.buttons` only: the places to switch the button on, or off. A
        /// step carries them rather than being three steps, because "show this
        /// agent" is one decision the reader can then qualify — and because the
        /// other two steps have nowhere to put such a thing.
        var surfaces: Set<AgentButtonSurface> = []

        var id: String { "\(agent.rawValue).\(step.rawValue).\(direction.rawValue)" }
    }

    /// What the reader wants this agent to *be*, when they press Finish.
    ///
    /// The end state, not a list of additions. Everything in it that the agent
    /// does not have is installed; everything the agent has that is not in it
    /// is removed. That is what makes the card a control rather than a form:
    /// the same three ticks that set an agent up are the ones that take it
    /// apart again.
    ///
    /// Per agent, because the row of checkboxes this replaced said one thing
    /// for everybody while the cards said another.
    struct Selection: Equatable, Sendable {
        var steps: Set<Step> = []
        var surfaces: Set<AgentButtonSurface> = []

        static let everything = Selection(
            steps: Set(Step.allCases), surfaces: Set(AgentButtonSurface.allCases))

        /// Ticking a place is also ticking "show the buttons": the parent line
        /// is a summary of its places, not a fourth thing to remember.
        var wantsButtons: Bool { steps.contains(.buttons) && !surfaces.isEmpty }

        /// Nothing asked for — which is what a switched-off agent is, and is
        /// read by `items` as "take out whatever it has".
        var isEmpty: Bool { steps.isEmpty && surfaces.isEmpty }
    }

    /// What the state of one agent is, as the panel found it.
    struct AgentState: Equatable, Sendable {
        var hooksInstalled: Bool
        var mcpRegistered: Bool

        /// Where this agent's button is already on. A set rather than a flag,
        /// because the three places are three preferences and a reader can
        /// perfectly well want the button on a tab row and not in the toolbar.
        var buttonsShown: Set<AgentButtonSurface>

        /// Nothing left for the panel to do.
        var isComplete: Bool {
            hooksInstalled && mcpRegistered
                && buttonsShown == Set(AgentButtonSurface.allCases)
        }

        func has(_ step: Step) -> Bool {
            switch step {
            case .hooks: return hooksInstalled
            case .mcp: return mcpRegistered
            case .buttons: return buttonsShown == Set(AgentButtonSurface.allCases)
            }
        }

        /// The places this agent's button is not on yet.
        var missingSurfaces: Set<AgentButtonSurface> {
            Set(AgentButtonSurface.allCases).subtracting(buttonsShown)
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
        selection: [CodingAgent: Selection],
        state: [CodingAgent: AgentState]
    ) -> [Item] {
        var work: [Item] = []

        /// Removals first, and per step rather than per agent, so a plan reads
        /// the way it happens: everything that is coming out comes out before
        /// anything goes in. An agent being switched off and another being
        /// switched on in the same press then cannot interleave.
        for direction in [Direction.remove, Direction.add] {
            for step in Step.allCases {
                for agent in CodingAgent.allCases {
                    let current = state[agent] ?? AgentState(
                        hooksInstalled: false, mcpRegistered: false, buttonsShown: [])

                    /// A missing selection is a switched-off agent, which wants
                    /// nothing — not an agent with no opinion.
                    let wanted = selection[agent] ?? Selection()

                    if step == .buttons {
                        /// The step is the gate and the places qualify it, the
                        /// same way the card treats them: a selection holding
                        /// places but not `.buttons` is asking for no button at
                        /// all, and reading the places alone there would switch
                        /// on three of them.
                        let asked = wanted.steps.contains(.buttons) ? wanted.surfaces : []
                        let places = direction == .add
                            ? asked.subtracting(current.buttonsShown)
                            : current.buttonsShown.subtracting(asked)
                        guard !places.isEmpty else { continue }
                        work.append(
                            Item(agent: agent, step: step, direction: direction,
                                 surfaces: places))
                        continue
                    }

                    let has = current.has(step)
                    let asked = wanted.steps.contains(step)
                    guard direction == .add ? (asked && !has) : (has && !asked) else { continue }
                    work.append(Item(agent: agent, step: step, direction: direction))
                }
            }
        }
        return work
    }

    /// The same, for one set of steps applied to everybody — which is what the
    /// row of checkboxes at the bottom of the panel means.
    static func items(
        chosen: [CodingAgent],
        steps: Set<Step>,
        state: [CodingAgent: AgentState]
    ) -> [Item] {
        let selection = Dictionary(uniqueKeysWithValues: chosen.map {
            ($0, Selection(
                steps: steps,
                surfaces: steps.contains(.buttons) ? Set(AgentButtonSurface.allCases) : []))
        })
        return items(selection: selection, state: state)
    }

    /// The line under the checkboxes. It names what will happen and to whom,
    /// because a switch and three ticks are not a sentence anybody can check.
    static func summary(
        selection: [CodingAgent: Selection],
        state: [CodingAgent: AgentState]
    ) -> String {
        let work = items(selection: selection, state: state)
        guard !work.isEmpty else {
            return "Nothing to change. Finish just closes this window."
        }

        let sentences = [Direction.add, .remove].compactMap { direction -> String? in
            let part = work.filter { $0.direction == direction }
            guard !part.isEmpty else { return nil }

            let steps = Step.allCases
                .filter { step in part.contains { $0.step == step } }
                .map(\.summaryName)
            let agents = CodingAgent.allCases
                .filter { agent in part.contains { $0.agent == agent } }
                .map(\.displayName)

            let verb = direction == .add ? "sets up" : "removes"
            return "\(verb) \(list(steps)) for \(list(agents))"
        }

        return "Finish " + list(sentences) + ". Everything here is in Settings too."
    }

    /// The same, for one set of steps applied to everybody — the shape the
      /// tests use to say "these agents, all of it".
    static func summary(
        chosen: [CodingAgent],
        steps: Set<Step>,
        state: [CodingAgent: AgentState]
    ) -> String {
        let selection = Dictionary(uniqueKeysWithValues: chosen.map {
            ($0, Selection(
                steps: steps,
                surfaces: steps.contains(.buttons) ? Set(AgentButtonSurface.allCases) : []))
        })
        return summary(selection: selection, state: state)
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
