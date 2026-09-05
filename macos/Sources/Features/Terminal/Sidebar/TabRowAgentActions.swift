import Foundation

/// Which agents a tab row offers to start.
///
/// The sidebar header and the group header have had these buttons all along,
/// where they make a *new* tab. On a tab you already have, the same gesture
/// means something narrower — run the agent in this shell — and it comes with a
/// rule the other two never needed.
enum TabRowAgentActions {
    /// Whether a session is up in this tab *now*.
    ///
    /// `AgentTabRecord.liveAgent` is a file's word, and the file is written by
    /// the agent's own hook. Two of the six agents have no session-end event
    /// to hook at all — the OpenCode plugin reports `working`, `done` and
    /// `awaiting` and nothing else, and Antigravity's descriptor registers
    /// working and done alone — and none of the other four gets to write its last word when
    /// the process goes down without reaching its exit path. So a tab whose
    /// agent the reader killed keeps a file that says `working`, forever, and
    /// the row went on hiding every button on the strength of it. That is the
    /// bug: one interrupted agent and the tab never offered to start another.
    ///
    /// The foreground process settles it without asking the file. A terminal
    /// whose foreground process is its own shell has nothing running on top of
    /// it, whatever the file claims — that is what `TerminalIdleCheck.isIdle`
    /// measures, and the worktree button on this same row already trusts it.
    ///
    /// Only in that direction. `isIdle` is false for a process it cannot read,
    /// and a tab that has not reported a foreground pid yet must not lose its
    /// buttons over it, so the evidence is allowed to *withdraw* a stale claim
    /// and never to make a new one.
    ///
    /// Deliberately not pushed down into `AgentTabRecord.liveAgent`. That fact
    /// also decides whether `AgentSessionResume` brings a conversation back at
    /// the next launch, and at launch there is no process left to ask.
    static func hasLiveAgent(_ liveAgent: CodingAgent?, isIdle: Bool) -> Bool {
        liveAgent != nil && !isIdle
    }

    /// The buttons to draw, in a fixed order, or none.
    ///
    /// None while a session is already live in the tab, and that is the whole
    /// reason this is a function rather than a filter at the call site. These
    /// buttons type a command into a shell. A tab sitting at a Claude prompt —
    /// including one that merely finished a turn and is waiting, which is most
    /// of the time — would receive the word `codex` as a *prompt*, and the
    /// reader would have asked an agent to explain the name of another one.
    /// That case survives the idle test on its own: the foreground process of
    /// a waiting agent is `claude`, not a shell.
    ///
    /// The liveness is `hasLiveAgent` above — `AgentTabRecord.liveAgent` read
    /// against the foreground process. A tab whose agent the reader quit, and
    /// a tab whose agent died without saying so, both report no session and
    /// get their buttons back, which is exactly when they are wanted again.
    ///
    /// Order is fixed rather than following the set, so the buttons do not
    /// reshuffle between rows or between launches.
    static func agents(
        shown: Set<CodingAgent>,
        liveAgent: CodingAgent?,
        isIdle: Bool
    ) -> [CodingAgent] {
        guard !hasLiveAgent(liveAgent, isIdle: isIdle) else { return [] }
        return CodingAgent.allCases.filter(shown.contains)
    }
}
