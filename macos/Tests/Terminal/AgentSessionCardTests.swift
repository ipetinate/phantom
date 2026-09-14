@testable import Ghostty
import Foundation
import Testing

struct AgentSessionCardTests {
    private let alpha = UUID()
    private let beta = UUID()
    private let gamma = UUID()

    private func facts(_ id: UUID, title: String = "Terminal") -> AgentSessionSurfaceFacts {
        AgentSessionSurfaceFacts(id: id, title: title, pwd: "/tmp/project")
    }

    @Test func processEvidenceNeverMakesAClaim() {
        #expect(AgentSessionComposer.liveness(
            hasSurface: true, foregroundName: nil, isIdle: nil) == .unknown)
        #expect(AgentSessionComposer.liveness(
            hasSurface: true, foregroundName: "zsh", isIdle: true) == .ended)
        #expect(AgentSessionComposer.liveness(
            hasSurface: true, foregroundName: "claude", isIdle: false) == .running)
        #expect(AgentSessionComposer.liveness(
            hasSurface: false, foregroundName: nil, isIdle: nil) == .ended)
    }

    @Test func aSessionWithoutASurfaceIsHiddenUnlessAskedFor() {
        let input = AgentSessionComposer.Input(
            records: [alpha: AgentTabRecord(stateWord: "working", agent: .claude)],
            states: [alpha: .working])

        #expect(AgentSessionComposer.compose(input).isEmpty)

        var withOrphans = input
        withOrphans.includeOrphans = true
        #expect(AgentSessionComposer.compose(withOrphans).count == 1)
    }

    @Test func aFileWithNoAgentAndNoStateIsNotASession() {
        let input = AgentSessionComposer.Input(
            records: [alpha: AgentTabRecord(fileContents: "")],
            surfaces: [facts(alpha)])
        #expect(AgentSessionComposer.compose(input).isEmpty)
    }

    @Test func attentionSortsAboveWorkAndOldestFirstWithinABand() {
        let now = Date()
        let input = AgentSessionComposer.Input(
            records: [
                alpha: AgentTabRecord(stateWord: "working", agent: .claude),
                beta: AgentTabRecord(stateWord: "awaiting", agent: .codex),
                gamma: AgentTabRecord(stateWord: "awaiting", agent: .opencode),
            ],
            states: [alpha: .working, beta: .awaiting, gamma: .awaiting],
            updatedAt: [
                alpha: now,
                beta: now.addingTimeInterval(-60),
                gamma: now.addingTimeInterval(-600),
            ],
            surfaces: [facts(alpha), facts(beta), facts(gamma)])

        let ids = AgentSessionComposer.compose(input).map(\.id)
        #expect(ids == [gamma, beta, alpha])
    }

    @Test func searchLooksAtTitleProjectAndAgent() {
        let input = AgentSessionComposer.Input(
            records: [
                alpha: AgentTabRecord(stateWord: "working", agent: .claude),
                beta: AgentTabRecord(stateWord: "working", agent: .codex),
            ],
            states: [alpha: .working, beta: .working],
            surfaces: [facts(alpha, title: "aurora api"), facts(beta, title: "phantom")])

        let cards = AgentSessionComposer.compose(input)
        #expect(AgentSessionFilter.apply(cards, query: "aurora", states: []).map(\.id) == [alpha])
        #expect(AgentSessionFilter.apply(cards, query: "codex", states: []).map(\.id) == [beta])
        #expect(AgentSessionFilter.apply(cards, query: "  ", states: []).count == 2)
    }

    @Test func stateChipsNarrowTheList() {
        let input = AgentSessionComposer.Input(
            records: [
                alpha: AgentTabRecord(stateWord: "working", agent: .claude),
                beta: AgentTabRecord(stateWord: "awaiting", agent: .codex),
            ],
            states: [alpha: .working, beta: .awaiting],
            surfaces: [facts(alpha), facts(beta)])

        let cards = AgentSessionComposer.compose(input)
        #expect(AgentSessionFilter.apply(cards, query: "", states: [.awaiting]).map(\.id) == [beta])
        #expect(AgentSessionFilter.apply(cards, query: "", states: []).count == 2)
    }
}
