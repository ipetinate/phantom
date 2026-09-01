import Foundation
@testable import Ghostty
import Testing

/// What the welcome window's last step is about to do, and the sentence it
/// shows for it.
///
/// The list and the sentence come from the same function on purpose: a panel
/// that says one thing and does another is worse than one that says nothing,
/// and this is a panel that writes into other applications' configuration.
struct WelcomeSetupPlanTests {
    private func state(
        hooks: Bool = false,
        mcp: Bool = false,
        buttons: Bool = false,
        places: Set<AgentButtonSurface>? = nil
    ) -> WelcomeSetupPlan.AgentState {
        WelcomeSetupPlan.AgentState(
            hooksInstalled: hooks,
            mcpRegistered: mcp,
            buttonsShown: places ?? (buttons ? Set(AgentButtonSurface.allCases) : []))
    }

    private let everything = Set(WelcomeSetupPlan.Step.allCases)

    // MARK: The work

    @Test func anAgentWithNothingSetUpGetsAllThreeSteps() {
        let work = WelcomeSetupPlan.items(
            chosen: [.claude], steps: everything, state: [.claude: state()])

        #expect(work.map(\.step) == [.hooks, .mcp, .buttons])
        #expect(work.allSatisfy { $0.agent == .claude })
    }

    /// Already-done work is left out rather than repeated. Every installer is
    /// idempotent so repeating would be harmless — but the list is also what
    /// the reader is shown, and offering to install hooks somebody has had
    /// since March makes the panel less believable, not more.
    @Test func whatIsAlreadyDoneIsNotOfferedAgain() {
        let work = WelcomeSetupPlan.items(
            chosen: [.claude],
            steps: everything,
            state: [.claude: state(hooks: true, buttons: true)])

        #expect(work.map(\.step) == [.mcp])
    }

    @Test func anAgentWithNothingLeftToDoProducesNoWork() {
        let complete = state(hooks: true, mcp: true, buttons: true)

        #expect(complete.isComplete)
        #expect(WelcomeSetupPlan.items(
            chosen: [.claude], steps: everything, state: [.claude: complete]).isEmpty)
    }

    /// An unticked checkbox drops that step for every agent, not just the
    /// first.
    @Test func anUntickedStepIsDroppedEverywhere() {
        let work = WelcomeSetupPlan.items(
            chosen: [.claude, .codex],
            steps: [.hooks, .buttons],
            state: [.claude: state(), .codex: state()])

        #expect(!work.contains { $0.step == .mcp })
        #expect(work.filter { $0.step == .hooks }.map(\.agent) == [.claude, .codex])
    }

    /// Hooks, then the MCP entry, then this app's own preferences: slowest and
    /// most consequential first, so a failure happens before the cheap writes
    /// rather than after them.
    @Test func theOrderIsHooksThenMCPThenButtons() {
        let work = WelcomeSetupPlan.items(
            chosen: [.claude, .codex],
            steps: everything,
            state: [.claude: state(), .codex: state()])

        #expect(work.map(\.step) == [.hooks, .hooks, .mcp, .mcp, .buttons, .buttons])
    }

    /// An agent nobody chose is never touched, whatever the checkboxes say.
    @Test func nothingHappensToAnAgentThatWasNotChosen() {
        let work = WelcomeSetupPlan.items(
            chosen: [], steps: everything, state: [.claude: state()])

        #expect(work.isEmpty)
    }

    // MARK: The sentence under the checkboxes

    @Test func theSummaryNamesTheStepsAndTheAgents() {
        let summary = WelcomeSetupPlan.summary(
            chosen: [.claude, .codex],
            steps: everything,
            state: [.claude: state(), .codex: state()])

        #expect(summary.contains("Claude Code and Codex"))
        #expect(summary.contains("hooks"))
        #expect(summary.contains("reversible in Settings"))
    }

    /// The three states in which Finish does nothing all say so, because a
    /// button that says Finish and changes nothing is one somebody presses
    /// twice.
    @Test func doingNothingIsSaidOutLoud() {
        let nothingChosen = WelcomeSetupPlan.summary(
            chosen: [], steps: everything, state: [:])
        let nothingTicked = WelcomeSetupPlan.summary(
            chosen: [.claude], steps: [], state: [.claude: state()])
        let alreadyDone = WelcomeSetupPlan.summary(
            chosen: [.claude],
            steps: everything,
            state: [.claude: state(hooks: true, mcp: true, buttons: true)])

        #expect(nothingChosen.contains("changes nothing"))
        #expect(nothingTicked.contains("changes nothing"))
        #expect(alreadyDone.contains("already set up"))
    }

    /// The summary only names steps that are actually left, so an agent that
    /// needs one thing is not described as needing three.
    @Test func theSummaryNamesOnlyWhatIsLeft() {
        let summary = WelcomeSetupPlan.summary(
            chosen: [.claude],
            steps: everything,
            state: [.claude: state(hooks: true, buttons: true)])

        #expect(summary.contains("the MCP server"))
        #expect(!summary.contains("hooks"))
    }

    /// `MCP server` is not lowercased into a sentence. Reading "sets up mcp
    /// server" is the one thing in this panel somebody would recognise as
    /// wrong at a glance — it was, on the first build.
    @Test func theSummaryKeepsTheSpellingOfANameThatIsAnAcronym() {
        let summary = WelcomeSetupPlan.summary(
            chosen: [.claude], steps: [.mcp], state: [.claude: state()])

        #expect(summary.contains("the MCP server"))
        #expect(!summary.lowercased().contains(" mcp server") || summary.contains("MCP"))
    }

    /// An agent that is already set up stays switched on — that is a true
    /// statement about the machine — but the sentence does not promise work
    /// for it. Measured on screen: the panel offered to set up Claude Code,
    /// whose card said, two inches above, that it was done.
    @Test func theSummaryNamesOnlyTheAgentsWithWorkLeft() {
        let summary = WelcomeSetupPlan.summary(
            chosen: [.claude, .codex],
            steps: everything,
            state: [
                .claude: state(hooks: true, mcp: true, buttons: true),
                .codex: state(),
            ])

        #expect(summary.contains("Codex"))
        #expect(!summary.contains("Claude Code"))
    }

    // MARK: One agent at a time

    /// The panel's own reason for existing in this shape: hooks and the MCP
    /// server for both agents, but the buttons for only one of them. With one
    /// set of checkboxes for everybody that took a second trip through
    /// Settings to undo.
    @Test func eachAgentGetsWhatItsOwnCardAsksFor() {
        let work = WelcomeSetupPlan.items(
            selection: [
                .claude: WelcomeSetupPlan.Selection(
                    steps: everything, surfaces: Set(AgentButtonSurface.allCases)),
                .codex: WelcomeSetupPlan.Selection(steps: [.hooks, .mcp], surfaces: []),
            ],
            state: [.claude: state(), .codex: state()])

        #expect(work.filter { $0.agent == .codex }.map(\.step) == [.hooks, .mcp])
        #expect(work.contains { $0.agent == .claude && $0.step == .buttons })
    }

    /// The places are a set, not a flag: somebody can want the button on tab
    /// rows and nowhere else.
    @Test func onlyTheChosenPlacesAreWritten() {
        let work = WelcomeSetupPlan.items(
            selection: [
                .claude: WelcomeSetupPlan.Selection(steps: [.buttons], surfaces: [.tabRow]),
            ],
            state: [.claude: state()])

        #expect(work.count == 1)
        #expect(work.first?.surfaces == [.tabRow])
    }

    /// A place the button is already on is not written again, and an agent
    /// whose places are all covered produces no work at all.
    @Test func placesAlreadyOnAreLeftAlone() {
        let selection = [
            CodingAgent.claude: WelcomeSetupPlan.Selection(
                steps: [.buttons], surfaces: Set(AgentButtonSurface.allCases)),
        ]

        let partial = WelcomeSetupPlan.items(
            selection: selection, state: [.claude: state(places: [.tabRow])])
        let complete = WelcomeSetupPlan.items(
            selection: selection,
            state: [.claude: state(places: Set(AgentButtonSurface.allCases))])

        #expect(partial.first?.surfaces == [.chrome, .groupHeader])
        #expect(complete.isEmpty)
    }

    /// An agent whose button is on in one place out of three is not "done" —
    /// the card still has two places to offer.
    @Test func oneePlaceOutOfThreeIsNotComplete() {
        #expect(!state(hooks: true, mcp: true, places: [.tabRow]).isComplete)
        #expect(state(hooks: true, mcp: true, places: Set(AgentButtonSurface.allCases))
            .isComplete)
    }

    /// Ticking the last place off takes the step with it, so an empty set is
    /// never written as an empty instruction.
    @Test func aButtonsStepWithNoPlacesIsNoWork() {
        let work = WelcomeSetupPlan.items(
            selection: [
                .claude: WelcomeSetupPlan.Selection(steps: [.buttons], surfaces: []),
            ],
            state: [.claude: state()])

        #expect(work.isEmpty)
    }

    /// Three or more agents read as a sentence rather than a comma-joined
    /// array.
    @Test func theListReadsLikeEnglish() {
        let summary = WelcomeSetupPlan.summary(
            chosen: [.claude, .codex, .opencode],
            steps: [.buttons],
            state: [.claude: state(), .codex: state(), .opencode: state()])

        #expect(summary.contains("Claude Code, Codex and OpenCode"))
    }
}
