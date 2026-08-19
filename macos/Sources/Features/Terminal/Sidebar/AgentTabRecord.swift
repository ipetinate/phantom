import Foundation

/// A coding agent Phantom can start in a terminal — and, after a restart,
/// put back into the conversation it was in.
///
/// Each CLI spells resumption differently, so the spellings live here rather
/// than as string literals at the restore site. Adding a fourth agent is then
/// a case with a command, not another branch threaded through the decoder.
///
/// All three spellings are now verified against running binaries rather than
/// against documentation: each CLI's own `--help` was read for the resume
/// syntax (`claude --resume <id>`, `codex resume <SESSION_ID>`,
/// `opencode --session <id>`), and each was then started and its session id
/// read back out of the store it keeps — UUIDs from Claude Code and Codex,
/// a `ses_`-prefixed token from OpenCode. Those are the shapes
/// `AgentTabRecord.sanitized(sessionID:)` has to pass through untouched, and
/// the ones `AgentSessionStore` reads back when no hook reported an id.
enum CodingAgent: String, Sendable, CaseIterable {
    case claude
    case codex
    case opencode

    /// What to call this agent in the interface.
    ///
    /// Here beside `launchCommand` because the two are the same fact read two
    /// ways — what the reader calls it and what the shell calls it — and a
    /// fourth agent should have to answer both in one place.
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }

    /// What starts a fresh session with this agent.
    ///
    /// Here rather than at the call site so that starting an agent and
    /// resuming it cannot come to disagree about which agent a tab holds:
    /// the sidebar records the case and asks it for both commands.
    var launchCommand: String {
        rawValue
    }

    /// The command that resumes `sessionID` — or, when no id was ever
    /// captured, the closest thing the CLI offers.
    ///
    /// The id-less fallback is deliberate rather than a refusal to act: it is
    /// what Phantom did for every restore before session ids existed, namely
    /// pick up the most recent conversation in this directory. Two tabs on
    /// the same folder then land on the same conversation, which is the whole
    /// bug the ids fix — but landing in the wrong conversation is recoverable
    /// by hand, and landing in none at all costs the tab its reason to exist.
    func resumeCommand(sessionID: String?) -> String {
        guard let sessionID, !sessionID.isEmpty else {
            switch self {
            case .claude: return "claude --continue"
            case .codex: return "codex resume --last"
            case .opencode: return "opencode --continue"
            }
        }

        switch self {
        case .claude: return "claude --resume \(sessionID)"
        case .codex: return "codex resume \(sessionID)"
        case .opencode: return "opencode --session \(sessionID)"
        }
    }
}

/// The contents of a tab-state file, parsed.
///
/// The file began life holding one word — the agent's state — and still does
/// whenever a hook script installed by an older Phantom writes it. Everything
/// past the first line is `key=value` metadata that a current hook adds:
/// which agent is running, and the session id that lets a restored tab resume
/// *that* conversation rather than merely the newest one in the directory.
///
/// Parsing keeps the two eras compatible in the direction that matters — a
/// one-word file is a valid record that simply carries no metadata — because
/// the files on disk outlive any single build of the app, and a user who
/// upgrades mid-session should not have their sidebar go blank.
struct AgentTabRecord: Equatable, Sendable {
    /// The first line, verbatim.
    ///
    /// Kept as written rather than as a parsed `AgentTabState` because the
    /// hooks also write words that are not states — `notify`, the transient
    /// attention marker — and because rewriting the file must never quietly
    /// normalize away a word this build happens not to know.
    var stateWord: String

    /// Which agent wrote the file, when it said so. Absent for every file a
    /// pre-session-id hook wrote.
    var agent: CodingAgent?

    /// The agent's own id for the conversation in this tab.
    var sessionID: String?

    /// Whether the session in this tab ended *while Phantom was running*.
    ///
    /// The word `ended` alone cannot answer the question a restore has to ask,
    /// because both endings write it: the reader quitting the agent, and
    /// Phantom quitting and taking the agent down with it. Only one of those
    /// means "I am done with this conversation", and restoring the other is the
    /// whole reason ids were captured.
    ///
    /// What separates them is who was still alive to see it. An `ended` that a
    /// running, not-quitting Phantom watched arrive is one the reader caused —
    /// the app was sitting there, nothing was being torn down, and the agent
    /// stopped anyway. An `ended` that appears with nobody watching (written as
    /// the app exits, or found already in the file at the next launch) is the
    /// quit's doing, and stays resumable. `TabStateCenter` is the only writer
    /// of this field for exactly that reason: it is the thing that was
    /// watching. See `TabStateCenter.endMarking`.
    ///
    /// It is also self-healing, and that falls out of the format rather than
    /// being arranged: every hook writes the whole file and none of them knows
    /// this key, so the next event of a live session drops it. A `/clear`, a
    /// resume, a second agent started in the same tab — each one silently
    /// un-ends the tab, which is what should happen when a session is up again.
    var endedByUser: Bool

    /// Session ids are read off disk and typed into a live shell, so the only
    /// ones accepted are the ones that cannot mean anything else: no spaces,
    /// no quotes, no `;` and no `$`. Real ids — UUIDs from Claude Code and
    /// Codex, `ses_`-prefixed tokens from OpenCode — pass through untouched.
    private static let allowedIDCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )

    /// Long enough for any id these CLIs mint, short enough that a runaway
    /// file cannot become a runaway command line.
    private static let maxIDLength = 128

    /// The only value `end=` is ever written with. A different one is read as
    /// no mark at all: this field decides whether a conversation comes back, so
    /// a word neither end of the contract recognizes must not be guessed at.
    static let userEndMarker = "user"

    init(
        stateWord: String,
        agent: CodingAgent? = nil,
        sessionID: String? = nil,
        endedByUser: Bool = false
    ) {
        self.stateWord = stateWord
        self.agent = agent
        self.sessionID = sessionID.flatMap(Self.sanitized(sessionID:))
        self.endedByUser = endedByUser
    }

    init(fileContents raw: String) {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        self.stateWord = lines.first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.agent = nil
        self.sessionID = nil
        self.endedByUser = false

        for line in lines.dropFirst() {
            let field = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = field.firstIndex(of: "=") else { continue }
            let key = String(field[field.startIndex..<separator])
            let value = String(field[field.index(after: separator)...])

            switch key {
            case "agent": agent = CodingAgent(rawValue: value)
            case "session": sessionID = Self.sanitized(sessionID: value)
            case "end": endedByUser = value == Self.userEndMarker
            default: continue
            }
        }
    }

    /// The state this build recognizes, or nil for a word it does not — the
    /// attention marker, or a file cleared of its state but kept for its id.
    var state: AgentTabState? {
        AgentTabState(rawValue: stateWord)
    }

    /// Whether the record still says anything about *which* session this tab
    /// was running. A record that does is worth keeping on disk even once its
    /// state is spent; one that does not is just a file.
    var carriesIdentity: Bool {
        agent != nil || sessionID != nil
    }

    /// The agent whose session is up in this tab right now, or nil when none
    /// is — the one fact two separate features need to agree on.
    ///
    /// A restore asks it to decide whether to bring a conversation back, and
    /// the sidebar asks it to decide whether a plan tag has anything behind it.
    /// Answering it twice would let them disagree, and a tag that outlives its
    /// session is exactly what disagreement looks like.
    ///
    /// `agentState` cannot stand in for this. That is nil both for a tab that
    /// never had an agent and for one whose agent is merely idle — the shape a
    /// record takes the moment a `done` is looked at, which is when a plan is
    /// most likely to be worth showing.
    ///
    /// A record with neither a state word this build knows nor any identity is
    /// not evidence of a session; it is a file. Everything else with something
    /// in it counts, and a record that names no agent is Claude's, because that
    /// is how every other reader here treats a file written before `agent=`
    /// existed.
    var liveAgent: CodingAgent? {
        guard !endedByUser, state != .ended else { return nil }
        guard carriesIdentity || state != nil else { return nil }
        return agent ?? .claude
    }

    /// Whether an id from the agent's own on-disk store is worth going to look
    /// for — see `AgentSessionStore`, which does the looking.
    ///
    /// Four conditions, each of which is a reason not to bother:
    ///
    /// - **No named agent**, and there is nothing to query. A file with no
    ///   `agent=` line predates the metadata entirely; it is read as Claude's
    ///   for the resume, but guessing an agent and then hunting through that
    ///   agent's sessions on the strength of the guess is a different thing
    ///   from falling back to `claude --continue`.
    /// - **An id already**, and it wins outright. The hook that reported it
    ///   was inside the conversation this tab was holding; the store only
    ///   knows what was newest in the directory, which is a weaker claim.
    /// - **`ended`**, where the fallback is deliberately nothing at all. The
    ///   store cannot improve on that, because it is keyed by directory and so
    ///   inherits the exact imprecision the `ended` rule exists to refuse:
    ///   for a session somebody finished on purpose, "whatever is newest here"
    ///   is a guess whether it comes from a flag or from a file.
    /// - **Ended by the reader**, where there is nothing to resume at all, so
    ///   an id would only be looked up to be thrown away.
    var needsSessionLookup: Bool {
        agent != nil && sessionID == nil && state != .ended && !endedByUser
    }

    /// The on-disk form. The state word stays on the first line so that a
    /// Phantom old enough to read only that line still reads it correctly.
    var fileContents: String {
        var lines = [stateWord]
        if let agent { lines.append("agent=\(agent.rawValue)") }
        if let sessionID { lines.append("session=\(sessionID)") }
        if endedByUser { lines.append("end=\(Self.userEndMarker)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Rejects anything a shell would read as more than one word, returning
    /// nil so the caller falls back to the id-less behavior rather than
    /// running whatever the file happened to contain.
    static func sanitized(sessionID raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maxIDLength else { return nil }
        guard value.unicodeScalars.allSatisfy(allowedIDCharacters.contains) else {
            return nil
        }

        // A leading dash is refused on its own, even though the character set
        // above allows dashes everywhere else, because the id is not just
        // text — it is an argument. An id spelled
        // `--dangerously-skip-permissions` is a flag, and the resume command
        // would hand it to the agent as one.
        guard let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first)
        else { return nil }

        return value
    }

    /// What a restored surface should run, given the tab-state file its
    /// predecessor left behind — or nil when it should run nothing.
    ///
    /// A missing file means no agent was ever live in that tab. Every state
    /// word other than `ended` — including one this build does not recognize,
    /// and the empty one a start record carries — is read as "the agent was
    /// still up when we quit", which is both the pre-session-id behavior and
    /// the forgiving default for a file another program owns.
    ///
    /// An `end=user` mark outranks all of it and resumes nothing. That is the
    /// reader having quit the agent themselves, with Phantom watching it happen
    /// — see `endedByUser` — and a conversation somebody closed on purpose is
    /// not one they want typed back at them on the next launch. The tab still
    /// comes back; it comes back as the plain shell it would have been.
    ///
    /// The mark is honoured whatever word sits beside it, not only `ended`.
    /// Nothing writes that combination, so a record carrying one is a record in
    /// a state this build did not produce — and the safe reading of one of those
    /// is to restore less rather than to restore something invented.
    ///
    /// `ended` without that mark is the interesting one, and it turns on
    /// whether there is an id:
    ///
    /// - **With an id**, it resumes. Quitting Phantom kills the agent, and a
    ///   dying agent's own hook writes `ended` — so at quit time *every*
    ///   session says `ended`, and treating that as "finished on purpose"
    ///   meant nothing was ever resumed. The word cannot tell the two apart;
    ///   the id can, because it names the exact conversation the tab was for.
    ///   Reopening that conversation is what the tab existed to hold.
    /// - **Without one**, it does not. There is nothing to be precise about,
    ///   and the id-less fallback resumes "the most recent conversation in
    ///   this directory" — which for a session somebody deliberately ended is
    ///   a guess, and possibly somebody else's conversation.
    ///
    /// Registering a session-start hook strengthens that second rule rather
    /// than weakening it. It was written when "no id" mostly meant "no event
    /// ever carried one", so refusing to resume was the cautious reading of an
    /// ambiguous file. Now that an id arrives when the session opens, an
    /// `ended` record without one is far more likely to mean what it says: no
    /// session was ever there. The two remaining ways to reach it — a user who
    /// has not picked up the new hook registration yet, and a start payload
    /// that carried no id — are both cases where the only alternative is still
    /// the directory-scoped guess. So the answer stays no, for the same reason
    /// and with better evidence behind it.
    ///
    /// A file with no `agent=` line is Claude's: it is the only agent Phantom
    /// ever resumed before this metadata existed.
    static func resumeCommand(forStateFileContents contents: String?) -> String? {
        resumeCommand(forStateFileContents: contents, fallbackSessionID: nil)
    }

    /// The same decision, offered an id that came from somewhere other than
    /// the file — the agent's own session store, read because no hook ever
    /// got to report one.
    ///
    /// A separate entry point rather than a lookup inside the existing one, so
    /// that the decision stays a function of its arguments: whether to resume,
    /// and as what, is worth being able to check without a home directory in
    /// the room. The disk work lives at the call site
    /// (`AgentSessionResume.resume`), which is also where it can be got off
    /// the main thread.
    ///
    /// `fallbackSessionID` is taken only when `needsSessionLookup` says it
    /// would have been asked for. Gating it here as well as there means a
    /// caller that resolved an id eagerly, or resolved one for the wrong
    /// record, cannot slip it past the rules the record itself sets — the
    /// hook's id still wins, and `ended` still declines.
    static func resumeCommand(
        forStateFileContents contents: String?,
        fallbackSessionID: String?
    ) -> String? {
        guard let contents else { return nil }
        let record = AgentTabRecord(fileContents: contents)
        if record.endedByUser { return nil }
        if record.state == .ended, record.sessionID == nil { return nil }

        let sessionID = record.sessionID ?? (
            record.needsSessionLookup
                ? fallbackSessionID.flatMap(Self.sanitized(sessionID:))
                : nil
        )
        return (record.agent ?? .claude).resumeCommand(sessionID: sessionID)
    }
}
