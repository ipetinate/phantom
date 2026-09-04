import Foundation

/// The mark a row shows for a plain command.
///
/// Three cases rather than a reuse of `AgentTabState`, which is the vocabulary
/// of something that reports itself in words. A command reports an exit code,
/// so only what an exit code can say exists here — and no reader can be
/// tempted to ask a `brew install` whether it is `awaiting` input.
enum CommandRunMark: Equatable {
    /// Drawn as the spinner `working` draws.
    case running

    /// Drawn as the dot `done` draws.
    case finished

    /// Drawn as the triangle `failed` draws. Only a shell that reports its
    /// commands can produce this: a poll of the foreground process sees a
    /// command leave, never how it left.
    case failed(exitCode: Int)
}

/// What a tab is doing with a plain command, and which signal said so.
struct CommandRun: Equatable {
    enum Phase: Equatable {
        /// A command started, and it is too early to say what it is. Draws
        /// nothing: this is the window a full-screen program needs to reach
        /// the alternate screen, and the wait that keeps a short command from
        /// flashing a spinner.
        case pending(since: Date)

        /// A command is running.
        case running

        /// A full-screen program owns the tab. Draws nothing, now or when it
        /// exits — see `CommandRunRule`.
        case interactive

        /// A command ran and ended well, and the reader has not looked at the
        /// tab since.
        case finished

        /// A command ended with a non-zero exit code.
        case failed(exitCode: Int)

        /// Nothing to draw. Distinct from no state at all, which is what nil
        /// means: this keeps `isShellReported` for a tab that has news later.
        case idle
    }

    var phase: Phase

    /// Whether this tab's shell reports its own commands, through the OSC 133
    /// sequence that reaches the app as `command_started` and
    /// `command_finished`.
    ///
    /// Latched on the first such report and never cleared, because shell
    /// integration is a property of the shell and not of one command. What it
    /// buys is the right to ignore the poll: a shell that reports knows when a
    /// command starts and ends, while the poll only infers it from a process
    /// name, and the two disagree in ordinary cases — a shell function, a
    /// builtin, a command that finishes between two ticks.
    var isShellReported: Bool

    /// What the row draws, or nil for a phase that draws nothing.
    var mark: CommandRunMark? {
        switch phase {
        case .pending, .interactive, .idle: return nil
        case .running: return .running
        case .finished: return .finished
        case .failed(let code): return .failed(exitCode: code)
        }
    }

    /// The same tab with nothing to draw, and what is known about its shell
    /// kept.
    var cleared: CommandRun {
        .init(phase: .idle, isShellReported: isShellReported)
    }
}

/// The tab-state rule for a command no agent hook reports.
///
/// `TabStateCenter` knows what an agent is doing because the agent's own hooks
/// write it into a file. A `brew install`, a `pnpm add` or a shell script
/// writes nothing and never will, so the same marks come from two signals
/// underneath this rule:
///
/// - **The shell's own report.** With shell integration the shell emits OSC
///   133 around every command, which reaches the app as the `command_started`
///   and `command_finished` actions. This is the better signal on every axis:
///   the start is known at once instead of at the next poll, a command that
///   lives two seconds is seen at all, the finish carries the duration it ran
///   for, and it carries the exit code, which is the only way a row can say a
///   command *failed*.
/// - **A poll of the foreground process.** A shell without integration
///   reports nothing, and it must still get an indicator. This is the older
///   path and it stays underneath: it can only see that some program owns the
///   terminal, at the resolution of the poll.
///
/// A tab that has ever been reported ignores the poll from then on, and that
/// asymmetry is the whole reason the signal is part of the state rather than
/// an argument the caller forgets. Read the other way round, a poll tick that
/// happens to see a shell prompt would end a command the shell says is still
/// running.
///
/// Four facts take the row away from this rule, and each is a case the marks
/// would get wrong:
///
/// - **A full-screen program.** An editor, a pager or a system monitor holds
///   the terminal until the reader quits it, so a spinner for it never stops
///   and nobody is waiting for its exit code. The signal is the alternate
///   screen, which is what such a program switches to and what `brew install`
///   never touches — an honest fact about the terminal rather than a list of
///   program names somebody has to keep adding to.
/// - **A dev server.** It runs a watcher until it is killed, so the same
///   applies. `SidebarTabModel.devServerPort` is the exclusion, and it arrives
///   up to one `DevServerCenter` scan after the server starts — which is why a
///   port appearing must *clear* the phase rather than finish it. Otherwise
///   starting a dev server would leave a dot behind.
/// - **An agent.** Its hooks own that row and they say more than this rule
///   can. An agent tab is one whose record names a live agent, which stays
///   true across the idle stretch between turns where `agentState` is nil.
/// - **A tab the reader is looking at.** A command they watched finish is not
///   news, so it earns no dot. A *failure* is kept, which is what the agent
///   states do with the same two words.
///
/// Pure, and given `now` rather than reading a clock, because the transitions
/// are the part of this feature that can be wrong in a way no screenshot
/// shows.
enum CommandRunRule {
    /// What happened, from the point of view of the row.
    enum Signal: Equatable {
        /// The shell reported a command starting.
        case shellStarted

        /// The shell reported a command finishing. `exitCode` is nil when the
        /// shell reported none, which is not the same as zero and may not be
        /// read as a failure.
        case shellFinished(exitCode: Int?, duration: TimeInterval)

        /// No news: re-read the tab. This is the metadata poll, and it is also
        /// how the wait after a start is brought to an end.
        case tick
    }

    /// What a tab's foreground process says about it. Read only for a tab
    /// whose shell does not report its own commands.
    enum Foreground: Equatable {
        /// Sitting at a shell prompt, with nothing running on top of it.
        case shell

        /// Some program owns the terminal.
        case command

        /// No pid, or a pid whose name could not be read.
        case unknown
    }

    /// Everything the rule is allowed to know beyond the signal.
    struct Facts {
        var foreground: Foreground = .unknown
        var isAlternateScreen: Bool = false
        var hasAgentState: Bool = false
        var hasLiveAgent: Bool = false
        var hasDevServerPort: Bool = false
    }

    /// How long a reported command must run before the row says anything
    /// about it.
    ///
    /// One second does two jobs, which is why it is one number. It is the
    /// window a full-screen program needs to reach the alternate screen, so
    /// opening an editor draws nothing at all rather than a spinner that is
    /// taken away again. And it is the line under which a finish is not worth
    /// a dot: a command that ends inside it was never drawn, so nothing about
    /// it appears or disappears. A failure ignores it — an exit code is worth
    /// knowing however fast it arrived.
    static let shellMinimumDuration: TimeInterval = 1

    /// The same, for a tab the poll drives.
    ///
    /// `SidebarTabManager`'s metadata poll, to the second. The poll is the
    /// only thing that observes a foreground process, so anything shorter
    /// would not buy a shorter wait — it would only let a refresh that lands
    /// between two polls (a window becoming key, say) promote a command that
    /// has barely started. Matching the poll means a command shorter than one
    /// tick can reach no mark at all, and so cannot flash.
    static let pollMinimumDuration: TimeInterval = 5

    /// The next state for a tab, or nil when nothing has ever been observed
    /// in it.
    static func next(
        after previous: CommandRun?,
        signal: Signal,
        facts: Facts,
        now: Date
    ) -> CommandRun? {
        guard !facts.hasAgentState, !facts.hasLiveAgent, !facts.hasDevServerPort else {
            return previous?.cleared
        }

        switch signal {
        case .shellStarted:
            return .init(phase: .pending(since: now), isShellReported: true)

        case .shellFinished(let exitCode, let duration):
            return finish(previous, exitCode: exitCode, duration: duration, facts: facts)

        case .tick:
            guard let previous, previous.isShellReported else {
                return tickPolled(previous, facts: facts, now: now)
            }
            return tickReported(previous, facts: facts, now: now)
        }
    }

    /// The shell said a command ended.
    ///
    /// A full-screen program's exit is not a result: the reader quit an
    /// editor, and the row has been saying nothing about it all along.
    private static func finish(
        _ previous: CommandRun?,
        exitCode: Int?,
        duration: TimeInterval,
        facts: Facts
    ) -> CommandRun {
        let silent = CommandRun(phase: .idle, isShellReported: true)

        if case .interactive = previous?.phase { return silent }

        if let exitCode, exitCode != 0 {
            return .init(phase: .failed(exitCode: exitCode), isShellReported: true)
        }

        guard duration >= shellMinimumDuration else { return silent }
        return .init(phase: .finished, isShellReported: true)
    }

    /// A tick on a tab whose shell reports its commands.
    ///
    /// It may change what the row draws and it may never start or end a run,
    /// so the foreground process is not consulted at all here. What is left
    /// for it: end the wait after a start, notice a program that reached the
    /// alternate screen, and clear a dot the reader has now seen.
    private static func tickReported(
        _ previous: CommandRun,
        facts: Facts,
        now: Date
    ) -> CommandRun {
        switch previous.phase {
        case .pending(let since):
            if facts.isAlternateScreen {
                return .init(phase: .interactive, isShellReported: true)
            }
            guard now.timeIntervalSince(since) >= shellMinimumDuration else { return previous }
            return .init(phase: .running, isShellReported: true)

        case .running:
            guard facts.isAlternateScreen else { return previous }
            return .init(phase: .interactive, isShellReported: true)

        case .finished, .interactive, .failed, .idle:
            /// A dot waits for the reader, it does not expire. Selection used
            /// to clear it here, on the reasoning that a command somebody
            /// watched finish is not news — but the reader asked for the mark
            /// and tested it on the tab they were looking at, which is the tab
            /// a command is usually run in. It goes when they tap the row or
            /// when the next command starts, which is what an agent's `done`
            /// already does.
            return previous
        }
    }

    /// A tick on a tab that reports nothing, where the foreground process is
    /// all there is to go on.
    private static func tickPolled(
        _ previous: CommandRun?,
        facts: Facts,
        now: Date
    ) -> CommandRun? {
        switch facts.foreground {
        case .unknown:
            return previous

        case .command:
            if facts.isAlternateScreen {
                return .init(phase: .interactive, isShellReported: false)
            }
            switch previous?.phase {
            case .running, .interactive:
                return previous
            case .pending(let since):
                guard now.timeIntervalSince(since) >= pollMinimumDuration else { return previous }
                return .init(phase: .running, isShellReported: false)
            default:
                return .init(phase: .pending(since: now), isShellReported: false)
            }

        case .shell:
            switch previous?.phase {
            case .running:
                return .init(phase: .finished, isShellReported: false)
            case .finished:
                return previous
            case .failed:
                return previous
            default:
                return previous?.cleared
            }
        }
    }

    /// Reads the foreground process name the sidebar already resolved.
    ///
    /// A name that could not be read is `unknown`, never a command, and
    /// `unknown` holds the state where it is: an unreadable pid must be able
    /// neither to start a spinner nor to throw away a mark already earned.
    /// This is the opposite of `TerminalIdleCheck.isIdle`, which counts the
    /// unknown as busy because its callers are about to type into the tab.
    static func foreground(name: String?) -> Foreground {
        guard let name, !name.isEmpty else { return .unknown }
        return TerminalIdleCheck.isShell(name) ? .shell : .command
    }
}
