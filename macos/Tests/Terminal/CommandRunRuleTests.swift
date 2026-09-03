import Foundation
@testable import Ghostty
import Testing

/// The inferred half of the tab-state vocabulary: what a row says about a
/// command that reports nothing about itself.
///
/// Every case here is a transition, which is why the rule is a pure function
/// in the first place. A wrong transition does not look wrong in a screenshot
/// of a working row — it shows up as a spinner that never stops on a tab
/// running a dev server, or as a dot for a command that never ran.
struct CommandRunRuleTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// One turn of `SidebarTabManager`'s metadata poll, which is the only
    /// thing that observes a foreground process.
    private var tick: TimeInterval { CommandRunRule.minimumDuration }

    private func facts(
        _ foreground: CommandRunRule.Foreground,
        agentState: Bool = false,
        liveAgent: Bool = false,
        devServerPort: Bool = false,
        selected: Bool = false
    ) -> CommandRunRule.Facts {
        CommandRunRule.Facts(
            foreground: foreground,
            hasAgentState: agentState,
            hasLiveAgent: liveAgent,
            hasDevServerPort: devServerPort,
            isSelected: selected
        )
    }

    /// The whole feature, in the order it happens: a `brew install` starts in
    /// a tab nobody is looking at, spins while it runs, and leaves a dot.
    @Test func aCommandStartsAndStops() {
        var phase = CommandRunRule.next(after: nil, facts: facts(.command), now: start)
        #expect(phase == .pending(since: start))
        #expect(phase?.mark == nil)

        phase = CommandRunRule.next(after: phase, facts: facts(.command), now: start + tick)
        #expect(phase == .running)
        #expect(phase?.mark == .running)

        phase = CommandRunRule.next(after: phase, facts: facts(.shell), now: start + 2 * tick)
        #expect(phase == .finished)
        #expect(phase?.mark == .finished)
    }

    /// The minimum duration, from both sides. A command has to still be there
    /// a full poll later to earn a spinner, so nothing that finishes inside
    /// one tick can flash — and a refresh landing between two polls (a window
    /// becoming key) does not promote it early.
    @Test func aCommandShorterThanOnePollDrawsNothing() {
        let seen = CommandRunRule.next(after: nil, facts: facts(.command), now: start)

        let early = CommandRunRule.next(
            after: seen, facts: facts(.command), now: start + tick - 1
        )
        #expect(early == .pending(since: start))
        #expect(early?.mark == nil)

        let gone = CommandRunRule.next(after: seen, facts: facts(.shell), now: start + 1)
        #expect(gone == nil)
    }

    /// The exclusion the reader asked for by name. A dev server holds its
    /// watcher open until it is killed, so a spinner for it would never stop.
    ///
    /// The second half is the one that would have been missed: the port is
    /// resolved by a scan that runs on its own interval, so it arrives *after*
    /// the server is already the foreground process. A port appearing has to
    /// clear the phase, not finish it — otherwise starting a dev server leaves
    /// a dot behind for a command that never ended.
    @Test func aDevServerNeverSpins() {
        #expect(CommandRunRule.next(
            after: nil, facts: facts(.command, devServerPort: true), now: start
        ) == nil)

        let running = CommandRunRule.next(
            after: CommandRunRule.next(after: nil, facts: facts(.command), now: start),
            facts: facts(.command),
            now: start + tick
        )
        #expect(running == .running)

        #expect(CommandRunRule.next(
            after: running,
            facts: facts(.command, devServerPort: true),
            now: start + 2 * tick
        ) == nil)
    }

    /// An agent tab is not running "a command": its hooks own that row and
    /// they report more than this rule can infer. Both readings of liveness
    /// count — the state a hook wrote, and the record naming a live session,
    /// which is the one that survives the idle stretch between turns.
    @Test func anAgentTabIsLeftAlone() {
        let foregrounds: [CommandRunRule.Foreground] = [.command, .shell, .unknown]
        let phases: [CommandRunPhase?] = [nil, .running, .finished, .pending(since: start)]

        for foreground in foregrounds {
            for previous in phases {
                #expect(CommandRunRule.next(
                    after: previous,
                    facts: facts(foreground, agentState: true),
                    now: start
                ) == nil)

                #expect(CommandRunRule.next(
                    after: previous,
                    facts: facts(foreground, liveAgent: true),
                    now: start
                ) == nil)
            }
        }
    }

    /// A tab sitting at its prompt has finished nothing. Without this the
    /// whole sidebar would come up wearing dots on the first poll.
    @Test func aTabThatWasNeverRunningDoesNotBecomeDone() {
        #expect(CommandRunRule.next(after: nil, facts: facts(.shell), now: start) == nil)

        let seen = CommandRunRule.next(after: nil, facts: facts(.command), now: start)
        #expect(CommandRunRule.next(
            after: seen, facts: facts(.shell), now: start + tick
        ) == nil)
    }

    /// A dot is news, and a command the reader watched finish is not. Both
    /// paths are covered: one that ends while the tab is selected never earns
    /// a mark, and one that already earned it loses it when the tab is looked
    /// at — the same moment `TabStateCenter.clearDone` fires for an agent.
    @Test func lookingAtTheTabClearsTheMark() {
        let running = CommandRunRule.next(
            after: CommandRunRule.next(after: nil, facts: facts(.command), now: start),
            facts: facts(.command),
            now: start + tick
        )

        #expect(CommandRunRule.next(
            after: running, facts: facts(.shell, selected: true), now: start + 2 * tick
        ) == nil)

        #expect(CommandRunRule.next(
            after: .finished, facts: facts(.shell, selected: true), now: start
        ) == nil)

        #expect(CommandRunRule.next(
            after: .finished, facts: facts(.shell), now: start
        ) == .finished)
    }

    /// A spinner is still worth drawing on the tab the reader is looking at:
    /// only the badge is suppressed there, because only the badge is a thing
    /// to come back to.
    @Test func aSelectedTabStillSpins() {
        let seen = CommandRunRule.next(
            after: nil, facts: facts(.command, selected: true), now: start
        )
        #expect(CommandRunRule.next(
            after: seen, facts: facts(.command, selected: true), now: start + tick
        ) == .running)
    }

    /// A second command supersedes the first one's result rather than running
    /// under its dot.
    @Test func aNewCommandSupersedesTheLastResult() {
        let phase = CommandRunRule.next(
            after: .finished, facts: facts(.command), now: start
        )
        #expect(phase == .pending(since: start))
        #expect(phase?.mark == nil)
    }

    /// An unreadable pid says nothing, so it changes nothing. It must be able
    /// neither to start a spinner nor to throw away a mark already earned.
    @Test func anUnreadableForegroundHoldsThePhase() {
        #expect(CommandRunRule.next(after: nil, facts: facts(.unknown), now: start) == nil)
        #expect(CommandRunRule.next(
            after: .running, facts: facts(.unknown), now: start
        ) == .running)
        #expect(CommandRunRule.next(
            after: .finished, facts: facts(.unknown), now: start
        ) == .finished)
    }

    /// The reading of the process name the sidebar already resolved, which is
    /// what keeps this rule off the process table.
    @Test func theForegroundComesFromTheProcessName() {
        #expect(CommandRunRule.foreground(name: "zsh") == .shell)
        #expect(CommandRunRule.foreground(name: "fish") == .shell)
        #expect(CommandRunRule.foreground(name: "brew") == .command)
        #expect(CommandRunRule.foreground(name: "node") == .command)
        #expect(CommandRunRule.foreground(name: nil) == .unknown)
        #expect(CommandRunRule.foreground(name: "") == .unknown)
    }
}
