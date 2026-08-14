import Foundation

/// A coding agent Phantom can start in a terminal — and, after a restart,
/// put back into the conversation it was in.
///
/// Each CLI spells resumption differently, so the spellings live here rather
/// than as string literals at the restore site. Adding a fourth agent is then
/// a case with a command, not another branch threaded through the decoder.
///
/// ⚠️ Only the `claude` forms are verified against a running binary — it is
/// the one of the three installed on the machine this was written on, and
/// `claude --help` lists `-r, --resume [value]  Resume a conversation by
/// session ID`. The `codex` and `opencode` forms are taken from those
/// projects' published CLI references (`codex resume <SESSION_ID>` and
/// `opencode --session <id>`, each with a "most recent" variant) and have
/// never been executed here. Treat them as documented, not proven.
enum CodingAgent: String, Sendable {
    case claude
    case codex
    case opencode

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

    init(stateWord: String, agent: CodingAgent? = nil, sessionID: String? = nil) {
        self.stateWord = stateWord
        self.agent = agent
        self.sessionID = sessionID.flatMap(Self.sanitized(sessionID:))
    }

    init(fileContents raw: String) {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        self.stateWord = lines.first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.agent = nil
        self.sessionID = nil

        for line in lines.dropFirst() {
            let field = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = field.firstIndex(of: "=") else { continue }
            let key = String(field[field.startIndex..<separator])
            let value = String(field[field.index(after: separator)...])

            switch key {
            case "agent": agent = CodingAgent(rawValue: value)
            case "session": sessionID = Self.sanitized(sessionID: value)
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

    /// The on-disk form. The state word stays on the first line so that a
    /// Phantom old enough to read only that line still reads it correctly.
    var fileContents: String {
        var lines = [stateWord]
        if let agent { lines.append("agent=\(agent.rawValue)") }
        if let sessionID { lines.append("session=\(sessionID)") }
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
    /// A missing file means no agent was ever live in that tab. `ended` means
    /// one was and finished on purpose, and reviving it would be Phantom
    /// deciding the session was not really over. Every other word — including
    /// one this build does not recognize, and the empty one left behind when
    /// a finished tab's indicator is cleared — is read as "the agent was
    /// still up when we quit". That is both the pre-session-id behavior and
    /// the forgiving default for a file another program owns.
    ///
    /// A file with no `agent=` line is Claude's: it is the only agent Phantom
    /// ever resumed before this metadata existed.
    static func resumeCommand(forStateFileContents contents: String?) -> String? {
        guard let contents else { return nil }
        let record = AgentTabRecord(fileContents: contents)
        guard record.state != .ended else { return nil }
        return (record.agent ?? .claude).resumeCommand(sessionID: record.sessionID)
    }
}
