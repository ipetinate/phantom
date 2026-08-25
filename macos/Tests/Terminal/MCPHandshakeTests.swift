import Foundation
import Testing

@testable import Ghostty

/// The handshake, which is the only thing standing between a process on this
/// machine and a surface that can run commands in the reader's terminals.
struct MCPHandshakeTests {
    private func hello(
        version: Int = MCPHandshake.version,
        pid: Int32 = 4242,
        tab: String? = nil
    ) -> MCPHandshake.Hello {
        MCPHandshake.Hello(version: version, tabStateFile: tab, pid: pid, client: "test")
    }

    @Test func aMatchingVersionAndPeerIsAccepted() {
        let answer = MCPHandshake.answer(to: hello(), peerPID: 4242)
        #expect(answer == .accepted(surface: nil))
    }

    /// The helper ships inside the app, so a version that does not match is a
    /// process left over from an earlier build — worth saying, rather than
    /// answering with something it will misread.
    @Test func anOlderClientIsRefusedByVersion() {
        let answer = MCPHandshake.answer(to: hello(version: 0), peerPID: 4242)
        guard case .refused(let reason) = answer else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("v0"))
    }

    /// The claim is checked against the kernel. Without that the tab is
    /// whatever the caller typed, and the tab decides what the caller may do.
    @Test func aClaimThatDisagreesWithTheKernelIsRefused() {
        let answer = MCPHandshake.answer(to: hello(pid: 4242), peerPID: 9)
        guard case .refused(let reason) = answer else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("4242"))
        #expect(reason.contains("9"))
    }

    /// A connection this app cannot identify is exactly the one to turn away:
    /// it can reach the reader's terminals.
    @Test func anUnidentifiablePeerIsRefused() {
        let answer = MCPHandshake.answer(to: hello(), peerPID: nil)
        guard case .refused = answer else {
            Issue.record("expected a refusal")
            return
        }
    }

    @Test func theTabComesFromTheStateFilesName() {
        let id = UUID()
        let path = "/Users/dev/.cache/phantom/tab-states/\(id.uuidString)"
        let answer = MCPHandshake.answer(to: hello(tab: path), peerPID: 4242)
        #expect(answer == .accepted(surface: id))
    }

    /// Not an error: an agent can run in a terminal that is not Phantom's,
    /// and still ask things that need no tab. What an unknown tab may do is
    /// for the tools to decide.
    @Test func aPathThatNamesNoTabIsStillAccepted() {
        #expect(MCPHandshake.surface(fromTabStateFile: "/tmp/nope") == nil)
        #expect(MCPHandshake.surface(fromTabStateFile: "") == nil)
        #expect(MCPHandshake.surface(fromTabStateFile: nil) == nil)
        #expect(MCPHandshake.answer(to: hello(tab: "/tmp/nope"), peerPID: 4242)
            == .accepted(surface: nil))
    }

    /// The hello crosses a process boundary as JSON, so its field names are
    /// a contract with the helper — renaming one silently is a handshake that
    /// stops matching.
    @Test func theHelloSurvivesTheWire() throws {
        let sent = hello(tab: "/tmp/x")
        let data = try JSONEncoder().encode(sent)
        let back = try JSONDecoder().decode(MCPHandshake.Hello.self, from: data)
        #expect(back == sent)

        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("tabStateFile"))
        #expect(text.contains("version"))
        #expect(text.contains("pid"))
    }
}
