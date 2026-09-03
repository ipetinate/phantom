import Foundation

/// The mark a row shows for a plain command.
///
/// Two cases rather than a reuse of `AgentTabState`, which is the vocabulary
/// of something that reports itself. A command reports nothing, so only the
/// two marks that can be inferred exist here — and no reader can be tempted
/// to ask a `brew install` whether it is `awaiting` input.
enum CommandRunMark: Equatable {
    /// Drawn as the spinner `working` draws.
    case running

    /// Drawn as the dot `done` draws.
    case finished
}

/// How far along a plain command in a tab is.
///
/// `pending` is the phase with nothing to draw, and it is the whole of the
/// minimum duration: a command is only worth a spinner once it has outlived
/// one poll of the foreground process. Holding that wait as a phase, rather
/// than as a timer somewhere, is what keeps the wait testable.
enum CommandRunPhase: Equatable {
    /// A command was seen, and has not yet run long enough to say so.
    case pending(since: Date)

    /// A command has been running since at least `CommandRunRule.minimumDuration`.
    case running

    /// A command ran, the tab is back at its prompt, and the reader has not
    /// looked at it since.
    case finished

    /// What the row draws, or nil for a phase that draws nothing.
    var mark: CommandRunMark? {
        switch self {
        case .pending: return nil
        case .running: return .running
        case .finished: return .finished
        }
    }
}

/// The tab-state rule for a command nobody instrumented.
///
/// `TabStateCenter` knows what an agent is doing because the agent's own hooks
/// write it into a file. A `brew install`, a `pnpm add` or a shell script
/// writes nothing and never will, so the same two marks have to be inferred
/// from the one fact the sidebar already gathers for every tab: its foreground
/// process. Nothing here reads a process, a clock or a file — the caller
/// passes what it already has.
///
/// Three facts can take the row away from this rule, and each is a case the
/// inference would get wrong:
///
/// - **A dev server.** It runs a watcher until it is killed, so a spinner for
///   it never stops. `SidebarTabModel.devServerPort` is the exclusion, and it
///   arrives up to one `DevServerCenter` scan after the server starts — which
///   is why a port appearing must *clear* the phase rather than finish it.
///   Otherwise starting a dev server would leave a dot behind.
/// - **An agent.** Its hooks own that row, and they say more than this rule
///   can. An agent tab is one whose record names a live agent, which stays
///   true across the idle stretch between turns where `agentState` is nil.
/// - **A tab the reader is looking at.** A command they watched finish is not
///   news, so it earns no dot.
///
/// Pure, and given `now` rather than reading a clock, because the transitions
/// are the part of this feature that can be wrong in a way no screenshot
/// shows.
enum CommandRunRule {
    /// What a tab's foreground process says about it.
    enum Foreground: Equatable {
        /// Sitting at a shell prompt, with nothing running on top of it.
        case shell

        /// Some program owns the terminal.
        case command

        /// No pid, or a pid whose name could not be read.
        case unknown
    }

    /// Everything the rule is allowed to know.
    struct Facts {
        var foreground: Foreground
        var hasAgentState: Bool = false
        var hasLiveAgent: Bool = false
        var hasDevServerPort: Bool = false
        var isSelected: Bool = false
    }

    /// How long a command must run before the row says so.
    ///
    /// `SidebarTabManager`'s metadata poll, to the second. The poll is the only
    /// thing that observes a foreground process, so anything shorter would not
    /// buy a shorter wait — it would only let a refresh that happens to land
    /// between two polls (a window becoming key, say) promote a command that
    /// has barely started. Matching the poll means a command shorter than one
    /// tick can reach neither mark, and so cannot flash.
    static let minimumDuration: TimeInterval = 5

    /// The next phase for a tab, or nil when its row has nothing to show.
    static func next(
        after previous: CommandRunPhase?,
        facts: Facts,
        now: Date
    ) -> CommandRunPhase? {
        guard !facts.hasAgentState, !facts.hasLiveAgent else { return nil }
        guard !facts.hasDevServerPort else { return nil }

        switch facts.foreground {
        case .unknown:
            return previous

        case .command:
            switch previous {
            case .running:
                return .running
            case .pending(let since):
                guard now.timeIntervalSince(since) >= minimumDuration else {
                    return .pending(since: since)
                }
                return .running
            case .finished, nil:
                return .pending(since: now)
            }

        case .shell:
            guard !facts.isSelected else { return nil }
            switch previous {
            case .running, .finished: return .finished
            case .pending, nil: return nil
            }
        }
    }

    /// Reads the foreground process name the sidebar already resolved.
    ///
    /// A name that could not be read is `unknown`, never a command, and
    /// `unknown` holds the phase where it is: an unreadable pid must be able
    /// neither to start a spinner nor to throw away a mark already earned.
    /// This is the opposite of `TerminalIdleCheck.isIdle`, which counts the
    /// unknown as busy because its callers are about to type into the tab.
    static func foreground(name: String?) -> Foreground {
        guard let name, !name.isEmpty else { return .unknown }
        return TerminalIdleCheck.isShell(name) ? .shell : .command
    }
}
