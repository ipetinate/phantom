import Foundation
@testable import Ghostty
import Testing

/// Telling the two ways an agent session ends apart, and what each one means
/// for the next launch.
///
/// Both write the word `ended`, which is why this needed a second field at all:
/// the reader quitting `claude` and Phantom quitting and killing `claude` were
/// the same three bytes on disk, so restore had to treat them the same way — and
/// treating them as resumable meant a session the reader had finished with came
/// back in that tab every launch, forever.
struct AgentSessionEndTests {
    private let id = "9f8e7d6c-1234-4abc-9def-0123456789ab"

    // MARK: - What restore does with each ending

    /// The bug, from the reader's side: they quit the agent, so it must not be
    /// waiting for them next time. The tab still returns — as a plain shell in
    /// the same directory — because nothing about the tab was ended.
    @Test func aSessionTheReaderEndedIsNotResumed() {
        for agent in [CodingAgent.claude, .codex, .opencode] {
            let record = AgentTabRecord(
                stateWord: "ended", agent: agent, sessionID: id, endedByUser: true
            )
            #expect(
                AgentTabRecord.resumeCommand(forStateFileContents: record.fileContents) == nil,
                "\(agent.rawValue) resumed a session the reader had ended"
            )
        }
    }

    /// The other ending, unchanged. Quitting Phantom kills every live agent and
    /// each dying agent's hook writes `ended`, and those are exactly the
    /// conversations worth typing back.
    @Test func aSessionKilledByTheQuitStillResumes() {
        let record = AgentTabRecord(stateWord: "ended", agent: .claude, sessionID: id)
        #expect(
            AgentTabRecord.resumeCommand(forStateFileContents: record.fileContents)
                == "claude --resume \(id)"
        )
    }

    /// The file on disk outlives any build of the app, and the reader runs dev
    /// builds over state an older one wrote. A record from before this field
    /// existed has to keep resuming exactly as it did — written out as literal
    /// bytes rather than through the encoder, because the encoder is the half
    /// that changed.
    @Test func aRecordWrittenByAnOlderSchemaResumesAsItAlwaysDid() {
        let legacy = "ended\nagent=codex\nsession=\(id)\n"
        #expect(
            AgentTabRecord.resumeCommand(forStateFileContents: legacy)
                == "codex resume \(id)"
        )
        #expect(!AgentTabRecord(fileContents: legacy).endedByUser)

        let oneWord = "working"
        #expect(!AgentTabRecord(fileContents: oneWord).endedByUser)
        #expect(
            AgentTabRecord.resumeCommand(forStateFileContents: oneWord) == "claude --continue"
        )
    }

    /// Only the one value Phantom writes counts as a mark. A key that arrives
    /// spelled some other way — a later build, another integration writing this
    /// file — must not be able to silently throw a conversation away.
    @Test func anUnrecognizedEndValueIsNotReadAsAMark() {
        let record = AgentTabRecord(fileContents: "ended\nagent=claude\nsession=\(id)\nend=maybe\n")
        #expect(!record.endedByUser)
        #expect(
            AgentTabRecord.resumeCommand(forStateFileContents: record.fileContents)
                == "claude --resume \(id)"
        )
    }

    /// A mark beside any other word is a record nothing in this build wrote, so
    /// it is read the cautious way round: no agent restored, tab still restored.
    @Test func theMarkIsHonouredBesideAnyStateWord() {
        for word in ["working", "done", "awaiting", "", "surprise"] {
            let record = AgentTabRecord(
                stateWord: word, agent: .claude, sessionID: id, endedByUser: true
            )
            #expect(
                AgentTabRecord.resumeCommand(forStateFileContents: record.fileContents) == nil,
                "a marked record spelled \"\(word)\" was resumed anyway"
            )
        }
    }

    /// The mark has to survive the round trip through the file, or it would be
    /// lost at the one moment it matters: the next launch.
    @Test func theMarkSurvivesTheFileFormat() {
        let original = AgentTabRecord(
            stateWord: "ended", agent: .opencode, sessionID: id, endedByUser: true
        )
        let parsed = AgentTabRecord(fileContents: original.fileContents)
        #expect(parsed == original)
        #expect(parsed.endedByUser)
        #expect(parsed.sessionID == id)
        #expect(parsed.agent == .opencode)
    }

    /// A marked record resumes nothing, so there is nothing to look an id up
    /// for — and an id resolved anyway, by a caller that asked eagerly, cannot
    /// smuggle the session back in.
    @Test func aMarkedRecordNeitherLooksUpAnIdNorAcceptsOne() {
        let record = AgentTabRecord(stateWord: "ended", agent: .claude, endedByUser: true)
        #expect(!record.needsSessionLookup)
        #expect(
            AgentTabRecord.resumeCommand(
                forStateFileContents: record.fileContents,
                fallbackSessionID: id
            ) == nil
        )
    }
}

/// Who gets marked, and when.
///
/// The word cannot say which ending it was, so the question asked is *when* it
/// arrived: an `ended` that a running, not-quitting Phantom watched appear is
/// the reader's doing, and everything else is left resumable.
@MainActor
struct AgentEndMarkingTests {
    private let id = "9f8e7d6c-1234-4abc-9def-0123456789ab"
    private let watchingSince = Date(timeIntervalSince1970: 1_000)
    private var duringThisRun: Date { watchingSince.addingTimeInterval(30) }
    private var beforeThisRun: Date { watchingSince.addingTimeInterval(-30) }

    private func ended() -> AgentTabRecord {
        AgentTabRecord(stateWord: "ended", agent: .claude, sessionID: id)
    }

    /// Phantom was up, nothing was being torn down, and a session stopped
    /// anyway: that is the reader quitting the agent. The rest of the record
    /// survives the mark — which agent, which conversation — because the tab
    /// still knows what it was holding.
    @Test func anEndSeenWhileTheAppWasUpIsTheReadersDoing() {
        let marked = TabStateCenter.endMarking(
            ended(), modified: duringThisRun, watchingSince: watchingSince, isQuitting: false
        )
        #expect(marked?.endedByUser == true)
        #expect(marked?.stateWord == "ended")
        #expect(marked?.agent == .claude)
        #expect(marked?.sessionID == id)
    }

    /// The case that must stay untouched. At quit every live agent dies and says
    /// `ended`; marking those is how a fix for one bug becomes a worse one.
    @Test func anEndDuringTheQuitIsLeftResumable() {
        #expect(TabStateCenter.endMarking(
            ended(), modified: duringThisRun, watchingSince: watchingSince, isQuitting: true
        ) == nil)
    }

    /// Every launch reads a directory full of `ended` files that the last quit
    /// left behind. None of them was witnessed, so none is attributable — and
    /// reading them as reader-ended would stop restoring anything at all.
    @Test func anEndFromBeforeThisRunIsNotAttributed() {
        #expect(TabStateCenter.endMarking(
            ended(), modified: beforeThisRun, watchingSince: watchingSince, isQuitting: false
        ) == nil)
    }

    /// A timestamp that could not be read arrives as `.distantPast`, and the
    /// direction to fail in is resuming a session too many, never discarding
    /// one.
    @Test func anUnreadableTimestampDegradesToResuming() {
        #expect(TabStateCenter.endMarking(
            ended(), modified: .distantPast, watchingSince: watchingSince, isQuitting: false
        ) == nil)
    }

    /// The mark is written into the same file the directory watch is watching,
    /// so a second mark on an already-marked record would be a write per event
    /// forever.
    @Test func anAlreadyMarkedRecordIsNotRewritten() {
        let marked = AgentTabRecord(
            stateWord: "ended", agent: .claude, sessionID: id, endedByUser: true
        )
        #expect(TabStateCenter.endMarking(
            marked, modified: duringThisRun, watchingSince: watchingSince, isQuitting: false
        ) == nil)
    }

    /// Nothing but an ending is an ending. `notify` in particular reaches
    /// `refresh` with its own handling and must not be diverted here.
    @Test func onlyAnEndedRecordIsEverMarked() {
        for word in ["working", "awaiting", "done", "failed", "denied", "notify", ""] {
            let record = AgentTabRecord(stateWord: word, agent: .claude, sessionID: id)
            #expect(
                TabStateCenter.endMarking(
                    record,
                    modified: duringThisRun,
                    watchingSince: watchingSince,
                    isQuitting: false
                ) == nil,
                "\"\(word)\" was treated as an ending"
            )
        }
    }

    /// Starting an agent in a tab whose last session the reader ended has to
    /// un-end the tab. Carrying the word forward would leave a live session
    /// looking finished to both readers of that fact: no plan tag, and a
    /// restore that declines it.
    @Test func startingAnAgentUnEndsTheTab() {
        let finished = AgentTabRecord(
            stateWord: "ended", agent: .claude, sessionID: id, endedByUser: true
        )
        #expect(TabStateCenter.startWord(carriedOver: finished).isEmpty)
        #expect(TabStateCenter.startWord(carriedOver: AgentTabRecord(stateWord: "ended")).isEmpty)
        #expect(TabStateCenter.startWord(carriedOver: nil).isEmpty)
    }

    /// A word that is still live news stays: an agent started in a tab that is
    /// already `working` is a second agent joining one that is still running,
    /// and blanking the word would drop that one's indicator.
    @Test func startingAnAgentKeepsALiveWord() {
        let working = AgentTabRecord(stateWord: "working", agent: .claude, sessionID: id)
        #expect(TabStateCenter.startWord(carriedOver: working) == "working")
    }
}

/// Whether a sidebar row draws the Plan tag.
///
/// The tag used to appear whenever the row's working directory sat inside a
/// plan's project, which made it a claim about a *folder* — and folders do not
/// end. It stayed on tabs whose Claude session was long gone and on tabs that
/// had never run an agent, where it stands for nothing. The liveness it needs is
/// the same fact restore uses, `AgentTabRecord.liveAgent`, so the two cannot
/// come to disagree about whether a session exists.
struct ClaudePlanTagVisibilityTests {
    private let id = "9f8e7d6c-1234-4abc-9def-0123456789ab"

    private func tagIsVisible(for record: AgentTabRecord?) -> Bool {
        ClaudePlanIndex.tagIsVisible(liveAgent: record?.liveAgent)
    }

    /// A Claude session that is up, in each of the shapes its record takes: mid
    /// turn, finished a turn, and idle — the last being what is left once a
    /// `done` has been looked at, which is exactly when a plan is worth showing.
    @Test func aLiveClaudeSessionEarnsTheTag() {
        for word in ["working", "done", "awaiting", ""] {
            let record = AgentTabRecord(stateWord: word, agent: .claude, sessionID: id)
            #expect(tagIsVisible(for: record), "a live session spelled \"\(word)\" lost its tag")
        }
    }

    /// The lie, both ways it is told: the session ended with the app, and the
    /// reader ended it. Either way there is nothing behind the tag.
    @Test func anEndedSessionLosesTheTag() {
        #expect(!tagIsVisible(for: AgentTabRecord(
            stateWord: "ended", agent: .claude, sessionID: id
        )))
        #expect(!tagIsVisible(for: AgentTabRecord(
            stateWord: "ended", agent: .claude, sessionID: id, endedByUser: true
        )))
    }

    /// A tab that never ran an agent has no record at all, and a file emptied
    /// of both its state and its identity says nothing about a session.
    @Test func aTabWithNoSessionNeverEarnsTheTag() {
        #expect(!tagIsVisible(for: nil))
        #expect(!tagIsVisible(for: AgentTabRecord(fileContents: "")))
    }

    /// A plan is Claude Code's. A tab running another agent in the same repo is
    /// not working that plan, however well the directory matches.
    @Test func anotherAgentsSessionDoesNotEarnAClaudePlanTag() {
        for agent in [CodingAgent.codex, .opencode] {
            let record = AgentTabRecord(stateWord: "working", agent: agent, sessionID: id)
            #expect(!tagIsVisible(for: record), "\(agent.rawValue) wore a Claude plan tag")
        }
    }

    /// A file with no `agent=` line was written by a hook old enough to predate
    /// the field, and that hook was Claude's — the reading every other decision
    /// here already makes.
    @Test func aRecordWithNoAgentLineIsClaudes() {
        let legacy = AgentTabRecord(fileContents: "working")
        #expect(legacy.liveAgent == .claude)
        #expect(tagIsVisible(for: legacy))
    }
}
