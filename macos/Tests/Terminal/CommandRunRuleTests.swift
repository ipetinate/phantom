import Foundation
@testable import Ghostty
import Testing

/// The inferred half of the tab-state vocabulary: what a row says about a
/// command that no agent hook reports.
///
/// Every case here is a transition, which is why the rule is a pure function
/// in the first place. A wrong transition does not look wrong in a screenshot
/// of a working row — it shows up as a spinner that never stops on a tab
/// running an editor, or as a dot for a command that never ran.
struct CommandRunRuleTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// One turn of `SidebarTabManager`'s metadata poll, which is all the
    /// resolution a tab without shell integration has.
    private var pollTick: TimeInterval { CommandRunRule.pollMinimumDuration }

    /// The wait after a reported start, which a full-screen program is
    /// expected to spend reaching the alternate screen.
    private var shellWait: TimeInterval { CommandRunRule.shellMinimumDuration }

    private func facts(
        _ foreground: CommandRunRule.Foreground = .unknown,
        alternateScreen: Bool = false,
        agentState: Bool = false,
        liveAgent: Bool = false,
        devServerPort: Bool = false
    ) -> CommandRunRule.Facts {
        CommandRunRule.Facts(
            foreground: foreground,
            isAlternateScreen: alternateScreen,
            hasAgentState: agentState,
            hasLiveAgent: liveAgent,
            hasDevServerPort: devServerPort
        )
    }

    private func next(
        _ previous: CommandRun?,
        _ signal: CommandRunRule.Signal,
        _ facts: CommandRunRule.Facts,
        at now: Date
    ) -> CommandRun? {
        CommandRunRule.next(after: previous, signal: signal, facts: facts, now: now)
    }

    /// A reported command that outlives the wait, from start to result. The
    /// whole point of the shell's report: the spinner is up a second in, not
    /// a poll in, and the dot does not need the foreground process to agree.
    @Test func aReportedCommandStartsAndStops() {
        var run = next(nil, .shellStarted, facts(), at: start)
        #expect(run?.phase == .pending(since: start))
        #expect(run?.mark == nil)
        #expect(run?.isShellReported == true)

        run = next(run, .tick, facts(), at: start + shellWait)
        #expect(run?.phase == .running)
        #expect(run?.mark == .running)

        run = next(
            run,
            .shellFinished(exitCode: 0, duration: 1.9),
            facts(.shell),
            at: start + 1.9
        )
        #expect(run?.phase == .finished)
        #expect(run?.mark == .finished)
    }

    /// The exit code, which only the shell can report. A non-zero one is the
    /// red mark, and it is kept on a tab the reader is looking at — the agent
    /// states treat `failed` the same way, while a `done` they watched is not
    /// news.
    @Test func aFailedCommandShowsItsExitCode() {
        let run = next(
            .init(phase: .running, isShellReported: true),
            .shellFinished(exitCode: 1, duration: 12),
            facts(.shell),
            at: start
        )
        #expect(run?.phase == .failed(exitCode: 1))
        #expect(run?.mark == .failed(exitCode: 1))

        /// A failure ignores the minimum duration: a command that fell over
        /// in a fifth of a second is the one worth marking.
        let quick = next(
            .init(phase: .running, isShellReported: true),
            .shellFinished(exitCode: 130, duration: 0.2),
            facts(.shell),
            at: start
        )
        #expect(quick?.mark == .failed(exitCode: 130))
    }

    /// A shell that reports no exit code is not a shell reporting zero. The
    /// difference is the whole reason the signal carries an optional.
    @Test func anUnreportedExitCodeIsNotAFailure() {
        let run = next(
            .init(phase: .running, isShellReported: true),
            .shellFinished(exitCode: nil, duration: 12),
            facts(.shell),
            at: start
        )
        #expect(run?.phase == .finished)
    }

    /// The minimum duration, on the reported path. A command that ends inside
    /// the wait was never drawn, so nothing about it appears or disappears —
    /// and the duration comes from the shell rather than from how many ticks
    /// happened to land.
    @Test func aReportedCommandUnderTheWaitDrawsNothing() {
        let started = next(nil, .shellStarted, facts(), at: start)
        let early = next(started, .tick, facts(), at: start + shellWait - 0.5)
        #expect(early?.phase == .pending(since: start))

        let run = next(
            started,
            .shellFinished(exitCode: 0, duration: 0.3),
            facts(.shell),
            at: start + 0.3
        )
        #expect(run?.mark == nil)
        #expect(run?.isShellReported == true)
    }

    /// The reason the wait exists at all. A full-screen program reaches the
    /// alternate screen inside it, so an editor draws nothing — not a spinner
    /// that is taken away again — and its exit is not a result anybody was
    /// waiting for.
    @Test func aFullScreenProgramDrawsNothingAndLeavesNothing() {
        let started = next(nil, .shellStarted, facts(), at: start)

        let editor = next(started, .tick, facts(alternateScreen: true), at: start + shellWait)
        #expect(editor?.phase == .interactive)
        #expect(editor?.mark == nil)

        let quit = next(
            editor,
            .shellFinished(exitCode: 0, duration: 900),
            facts(.shell),
            at: start + 900
        )
        #expect(quit?.mark == nil)
    }

    /// A pager that opens after the wait — `git log` handing off to `less` —
    /// takes the spinner away rather than keeping it forever.
    @Test func aProgramThatGoesFullScreenLateStopsTheSpinner() {
        let run = next(
            .init(phase: .running, isShellReported: true),
            .tick,
            facts(alternateScreen: true),
            at: start
        )
        #expect(run?.phase == .interactive)
    }

    /// The tab a poll drives: no shell integration, so the foreground process
    /// is all there is, at the resolution of the poll.
    @Test func aPolledCommandStartsAndStops() {
        var run = next(nil, .tick, facts(.command), at: start)
        #expect(run?.phase == .pending(since: start))
        #expect(run?.isShellReported == false)

        run = next(run, .tick, facts(.command), at: start + pollTick)
        #expect(run?.mark == .running)

        run = next(run, .tick, facts(.shell), at: start + 2 * pollTick)
        #expect(run?.mark == .finished)
    }

    /// The poll's own minimum duration, from both sides. A command has to
    /// still be there a full poll later to earn a spinner, so nothing that
    /// finishes inside one tick can flash — and a refresh landing between two
    /// polls (a window becoming key) does not promote it early.
    @Test func aPolledCommandShorterThanOnePollDrawsNothing() {
        let seen = next(nil, .tick, facts(.command), at: start)

        let early = next(seen, .tick, facts(.command), at: start + pollTick - 1)
        #expect(early?.phase == .pending(since: start))

        let gone = next(seen, .tick, facts(.shell), at: start + 1)
        #expect(gone?.mark == nil)
    }

    /// The alternate screen answers for the polled tab too, and without
    /// waiting: there is no start to wait from, so an editor is recognised on
    /// the first tick that sees it.
    @Test func aPolledFullScreenProgramDrawsNothing() {
        let run = next(nil, .tick, facts(.command, alternateScreen: true), at: start)
        #expect(run?.phase == .interactive)
        #expect(run?.mark == nil)

        let quit = next(run, .tick, facts(.shell), at: start + pollTick)
        #expect(quit?.mark == nil)
    }

    /// The asymmetry that makes the two signals one feature: once a shell has
    /// reported, a poll tick may change what is drawn but may not start or end
    /// a run. A shell function or a builtin looks like a prompt to the poll
    /// while the command is still running.
    @Test func anEventWinsOverAPollTickThatDisagrees() {
        let running = CommandRun(phase: .running, isShellReported: true)
        #expect(next(running, .tick, facts(.shell), at: start)?.phase == .running)

        let pending = CommandRun(phase: .pending(since: start), isShellReported: true)
        #expect(
            next(pending, .tick, facts(.shell), at: start + 0.1)?.phase
                == .pending(since: start)
        )

        let finished = CommandRun(phase: .finished, isShellReported: true)
        #expect(next(finished, .tick, facts(.command), at: start)?.phase == .finished)
    }

    /// The report is a property of the shell, not of one command, so the
    /// latch survives everything that clears the marks.
    @Test func theShellReportLatchSurvivesAClearedRow() {
        let finished = CommandRun(phase: .finished, isShellReported: true)

        let started = next(finished, .shellStarted, facts(.shell), at: start)
        #expect(started?.mark == nil)
        #expect(started?.isShellReported == true)

        let agent = next(finished, .tick, facts(.shell, liveAgent: true), at: start)
        #expect(agent?.isShellReported == true)
    }

    /// The exclusion the reader asked for by name. A dev server holds its
    /// watcher open until it is killed, so a spinner for it would never stop.
    ///
    /// The second half is the one that would have been missed: the port is
    /// resolved by a scan that runs on its own interval, so it arrives *after*
    /// the server is already running. A port appearing has to clear the row,
    /// not finish it — otherwise starting a dev server leaves a dot behind for
    /// a command that never ended.
    @Test func aDevServerNeverSpins() {
        #expect(next(nil, .tick, facts(.command, devServerPort: true), at: start) == nil)

        let running = CommandRun(phase: .running, isShellReported: true)
        let served = next(running, .tick, facts(.command, devServerPort: true), at: start)
        #expect(served?.mark == nil)

        let reportedStart = next(
            running, .shellStarted, facts(.command, devServerPort: true), at: start
        )
        #expect(reportedStart?.mark == nil)
    }

    /// An agent tab is not running "a command": its hooks own that row and
    /// they report more than this rule can. Both readings of liveness count —
    /// the state a hook wrote, and the record naming a live session, which is
    /// the one that survives the idle stretch between turns.
    @Test func anAgentTabIsLeftAlone() {
        let foregrounds: [CommandRunRule.Foreground] = [.command, .shell, .unknown]
        let phases: [CommandRun.Phase] = [
            .running, .finished, .failed(exitCode: 1), .pending(since: start), .interactive,
        ]
        let signals: [CommandRunRule.Signal] = [
            .tick, .shellStarted, .shellFinished(exitCode: 1, duration: 30),
        ]

        for foreground in foregrounds {
            for phase in phases {
                for signal in signals {
                    for reported in [true, false] {
                        let previous = CommandRun(phase: phase, isShellReported: reported)

                        #expect(next(
                            previous, signal, facts(foreground, agentState: true), at: start
                        )?.mark == nil)

                        #expect(next(
                            previous, signal, facts(foreground, liveAgent: true), at: start
                        )?.mark == nil)
                    }
                }
            }
        }
    }

    /// A tab sitting at its prompt has finished nothing. Without this the
    /// whole sidebar would come up wearing dots on the first poll.
    @Test func aTabThatWasNeverRunningDoesNotBecomeDone() {
        #expect(next(nil, .tick, facts(.shell), at: start) == nil)

        let seen = next(nil, .tick, facts(.command), at: start)
        #expect(next(seen, .tick, facts(.shell), at: start + pollTick)?.mark == nil)
    }

    /// A dot is news, and a command the reader watched finish is not. Both
    /// paths are covered: one that ends while the tab is selected never earns
    /// a mark, and one that already earned it loses it when the tab is looked
    /// at — the same moment `TabStateCenter.clearDone` fires for an agent.
    /// A dot waits for the reader rather than expiring. Selection used to
    /// clear it, on the reasoning that a command somebody watched finish is
    /// not news — but the tab a command runs in is usually the tab in front,
    /// so that rule meant the mark the reader asked for almost never showed.
    /// It goes on a tap or on the next command, which is what an agent's
    /// `done` already does.
    @Test func aFinishedMarkWaitsRatherThanExpiring() {
        let running = CommandRun(phase: .running, isShellReported: false)
        #expect(next(running, .tick, facts(.shell), at: start)?.mark == .finished)

        let reported = CommandRun(phase: .running, isShellReported: true)
        #expect(next(
            reported,
            .shellFinished(exitCode: 0, duration: 30),
            facts(.shell),
            at: start
        )?.mark == .finished)

        let finished = CommandRun(phase: .finished, isShellReported: false)
        #expect(next(finished, .tick, facts(.shell), at: start)?.mark == .finished)
    }

    /// A spinner is still worth drawing on the tab the reader is looking at:
    /// only the badge is suppressed there, because only the badge is a thing
    /// to come back to.
    /// The tab in front is the tab a command is run in, so both halves have
    /// to show there: the spinner while it runs and the dot when it ends.
    @Test func theTabInFrontShowsBothHalves() {
        let started = next(nil, .shellStarted, facts(), at: start)
        let running = next(started, .tick, facts(.command), at: start + shellWait)
        #expect(running?.mark == .running)

        #expect(next(
            running,
            .shellFinished(exitCode: 0, duration: 8),
            facts(.shell),
            at: start + shellWait
        )?.mark == .finished)
    }

    /// A second command supersedes the first one's result rather than running
    /// under its dot.
    @Test func aNewCommandSupersedesTheLastResult() {
        let finished = CommandRun(phase: .finished, isShellReported: true)
        let run = next(finished, .shellStarted, facts(), at: start)
        #expect(run?.phase == .pending(since: start))
        #expect(run?.mark == nil)

        let failed = CommandRun(phase: .failed(exitCode: 1), isShellReported: false)
        #expect(next(failed, .tick, facts(.command), at: start)?.mark == nil)
    }

    /// An unreadable pid says nothing, so it changes nothing on the tab that
    /// depends on it. It must be able neither to start a spinner nor to throw
    /// away a mark already earned.
    @Test func anUnreadableForegroundHoldsThePolledRow() {
        #expect(next(nil, .tick, facts(.unknown), at: start) == nil)

        let running = CommandRun(phase: .running, isShellReported: false)
        #expect(next(running, .tick, facts(.unknown), at: start)?.phase == .running)

        let finished = CommandRun(phase: .finished, isShellReported: false)
        #expect(next(finished, .tick, facts(.unknown), at: start)?.phase == .finished)
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
