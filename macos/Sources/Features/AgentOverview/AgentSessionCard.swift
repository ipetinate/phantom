import AppKit
import Foundation

enum AgentSessionLiveness: Equatable {
    case running
    case ended
    case unknown
}

struct AgentSessionCard: Identifiable, Equatable {
    let id: UUID
    let agent: CodingAgent
    let state: AgentTabState?
    let stateWord: String
    let endedByUser: Bool
    let sessionID: String?
    let lastEventAt: Date?
    let liveness: AgentSessionLiveness
    let foregroundName: String?
    let title: String
    let pwd: String?
    let groupID: UUID?
    let groupName: String?
    let worktreeBranch: String?
    let isFocused: Bool
    let previewLines: [String]

    var isOrphan: Bool { liveness == .ended && state == nil }

    var wantsAttention: Bool {
        state == .awaiting || state == .failed || state == .denied
    }

    static func == (lhs: AgentSessionCard, rhs: AgentSessionCard) -> Bool {
        lhs.id == rhs.id
            && lhs.agent == rhs.agent
            && lhs.state == rhs.state
            && lhs.stateWord == rhs.stateWord
            && lhs.endedByUser == rhs.endedByUser
            && lhs.sessionID == rhs.sessionID
            && lhs.lastEventAt == rhs.lastEventAt
            && lhs.liveness == rhs.liveness
            && lhs.foregroundName == rhs.foregroundName
            && lhs.title == rhs.title
            && lhs.pwd == rhs.pwd
            && lhs.groupID == rhs.groupID
            && lhs.groupName == rhs.groupName
            && lhs.worktreeBranch == rhs.worktreeBranch
            && lhs.isFocused == rhs.isFocused
            && lhs.previewLines == rhs.previewLines
    }
}

struct AgentSessionSurfaceFacts: Equatable {
    let id: UUID
    let title: String
    let pwd: String?
    let groupID: UUID?
    let groupName: String?
    let worktreeBranch: String?
    let isFocused: Bool

    init(
        id: UUID,
        title: String,
        pwd: String? = nil,
        groupID: UUID? = nil,
        groupName: String? = nil,
        worktreeBranch: String? = nil,
        isFocused: Bool = false
    ) {
        self.id = id
        self.title = title
        self.pwd = pwd
        self.groupID = groupID
        self.groupName = groupName
        self.worktreeBranch = worktreeBranch
        self.isFocused = isFocused
    }
}

enum AgentSessionComposer {
    struct Input {
        var records: [UUID: AgentTabRecord] = [:]
        var states: [UUID: AgentTabState] = [:]
        var updatedAt: [UUID: Date] = [:]
        var surfaces: [AgentSessionSurfaceFacts] = []
        var foregroundNames: [UUID: String] = [:]
        var idle: [UUID: Bool] = [:]
        var previews: [UUID: [String]] = [:]
        var includeOrphans = false
    }

    static func liveness(
        hasSurface: Bool,
        foregroundName: String?,
        isIdle: Bool?
    ) -> AgentSessionLiveness {
        guard hasSurface else { return .ended }
        guard let isIdle else { return .unknown }
        return isIdle ? .ended : .running
    }

    static func compose(_ input: Input) -> [AgentSessionCard] {
        let byID = Dictionary(
            input.surfaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var cards: [AgentSessionCard] = []

        for (id, record) in input.records {
            guard let agent = record.agent ?? record.liveAgent else { continue }
            let facts = byID[id]
            if facts == nil && !input.includeOrphans { continue }

            cards.append(AgentSessionCard(
                id: id,
                agent: agent,
                state: input.states[id],
                stateWord: record.stateWord,
                endedByUser: record.endedByUser,
                sessionID: record.sessionID,
                lastEventAt: input.updatedAt[id],
                liveness: liveness(
                    hasSurface: facts != nil,
                    foregroundName: input.foregroundNames[id],
                    isIdle: input.idle[id]),
                foregroundName: input.foregroundNames[id],
                title: facts?.title ?? record.sessionID ?? "Session",
                pwd: facts?.pwd,
                groupID: facts?.groupID,
                groupName: facts?.groupName,
                worktreeBranch: facts?.worktreeBranch,
                isFocused: facts?.isFocused ?? false,
                previewLines: input.previews[id] ?? []))
        }

        return sorted(cards)
    }

    static func sorted(_ cards: [AgentSessionCard]) -> [AgentSessionCard] {
        cards.sorted { left, right in
            let leftBand = band(left)
            let rightBand = band(right)
            if leftBand != rightBand { return leftBand < rightBand }
            let leftAt = left.lastEventAt ?? .distantFuture
            let rightAt = right.lastEventAt ?? .distantFuture
            if leftAt != rightAt { return leftAt < rightAt }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }

    private static func band(_ card: AgentSessionCard) -> Int {
        if card.wantsAttention { return 0 }
        switch card.state {
        case .working, .compacting: return 1
        case .done: return 2
        default: return 3
        }
    }
}

enum AgentSessionFilter {
    static func apply(
        _ cards: [AgentSessionCard],
        query: String,
        states: Set<AgentTabState>
    ) -> [AgentSessionCard] {
        var result = cards
        if !states.isEmpty {
            result = result.filter { card in
                guard let state = card.state else { return false }
                return states.contains(state)
            }
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return result }

        return result.filter { card in
            haystack(card).contains { $0.lowercased().contains(trimmed) }
        }
    }

    static func haystack(_ card: AgentSessionCard) -> [String] {
        [
            card.title,
            card.groupName,
            card.pwd,
            card.worktreeBranch,
            card.agent.displayName,
            card.sessionID,
        ].compactMap { $0 }
    }
}
