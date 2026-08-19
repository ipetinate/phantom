import Foundation

/// Which agents a tab row offers to start.
///
/// The sidebar header and the group header have had these buttons all along,
/// where they make a *new* tab. On a tab you already have, the same gesture
/// means something narrower — run the agent in this shell — and it comes with a
/// rule the other two never needed.
enum TabRowAgentActions {
    /// The buttons to draw, in a fixed order, or none.
    ///
    /// None while a session is already live in the tab, and that is the whole
    /// reason this is a function rather than a filter at the call site. These
    /// buttons type a command into a shell. A tab sitting at a Claude prompt —
    /// including one that merely finished a turn and is waiting, which is most
    /// of the time — would receive the word `codex` as a *prompt*, and the
    /// reader would have asked an agent to explain the name of another one.
    ///
    /// The liveness is `AgentTabRecord.liveAgent`, the same fact that decides
    /// whether a restore resumes a session and whether the plan tag is drawn.
    /// A tab whose agent the reader quit reports nil and gets its buttons back,
    /// which is exactly when they are wanted again.
    ///
    /// Order is fixed rather than following the set, so the buttons do not
    /// reshuffle between rows or between launches.
    static func agents(shown: Set<CodingAgent>, liveAgent: CodingAgent?) -> [CodingAgent] {
        guard liveAgent == nil else { return [] }
        return CodingAgent.allCases.filter(shown.contains)
    }
}
