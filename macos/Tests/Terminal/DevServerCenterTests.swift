@testable import Ghostty
import Combine
import Testing

@MainActor
@Suite(.serialized)
struct DevServerCenterTests {
    // MARK: - port(inColumns:)

    /// Real `lsof -iTCP -sTCP:LISTEN -P -n` rows, split the same way
    /// `listeningPorts()` splits them, so this is what actually reaches the
    /// parser rather than a hand-simplified string.
    private func columns(_ line: String) -> [Substring] {
        line.split(separator: " ", omittingEmptySubsequences: true)
    }

    @Test func parsesWildcardAddress() {
        let line = "node      35934 isac.petinate   47u  IPv4 0xbb46b3e3fb5ea6e      0t0  TCP *:4200 (LISTEN)"
        #expect(DevServerCenter.port(inColumns: columns(line)) == 4200)
    }

    @Test func parsesLoopbackAddress() {
        let line = "node      35934 isac.petinate   47u  IPv4 0xbb46b3e3fb5ea6e      0t0  TCP 127.0.0.1:4200 (LISTEN)"
        #expect(DevServerCenter.port(inColumns: columns(line)) == 4200)
    }

    @Test func parsesIPv6LoopbackAddress() {
        let line = "node      35934 isac.petinate   47u  IPv6 0xbb46b3e3fb5ea6e      0t0  TCP [::1]:4200 (LISTEN)"
        #expect(DevServerCenter.port(inColumns: columns(line)) == 4200)
    }

    /// The trailing `(LISTEN)` column must not be mistaken for the address:
    /// it has no colon, but this guards against a future column reordering
    /// that could make it look port-shaped.
    @Test func ignoresTrailingListenMarker() {
        let line = "rapportd   1118 isac.petinate   10u  IPv4 0xef81939da8d4b4cf      0t0    TCP *:59477 (LISTEN)"
        #expect(DevServerCenter.port(inColumns: columns(line)) == 59477)
    }

    @Test func returnsNilWhenNoColumnHasAPort() {
        let line = "COMMAND     PID          USER   FD   TYPE             DEVICE SIZE/OFF   NODE NAME"
        #expect(DevServerCenter.port(inColumns: columns(line)) == nil)
    }

    // MARK: - resolve(tracked:listeners:parents:)

    /// The real shape this exists for: a dev server sits several process
    /// layers below the tab's foreground job (`pnpm` -> `nx` -> `vite`), not
    /// as its direct child.
    @Test func attributesPortToTrackedAncestorSeveralHopsUp() {
        let tracked: Set<Int> = [100] // the surface's foreground PID (zsh)
        let parents: [Int: Int] = [
            200: 100, // pnpm, child of the shell
            300: 200, // nx, child of pnpm
            400: 300, // vite, child of nx — the actual listener
        ]
        let listeners: [Int: [Int]] = [400: [5173]]

        let resolved = DevServerCenter.resolve(tracked: tracked, listeners: listeners, parents: parents)
        #expect(resolved == [100: 5173])
    }

    @Test func attributesPortWhenListenerIsItselfTracked() {
        let tracked: Set<Int> = [400]
        let listeners: [Int: [Int]] = [400: [3000]]

        let resolved = DevServerCenter.resolve(tracked: tracked, listeners: listeners, parents: [:])
        #expect(resolved == [400: 3000])
    }

    /// The lowest port is treated as the server itself; higher ones on the
    /// same listener (an HMR or debug side channel) are dropped rather than
    /// overwriting it.
    @Test func picksTheLowestPortWhenAListenerHasSeveral() {
        let tracked: Set<Int> = [100]
        let parents: [Int: Int] = [400: 100]
        let listeners: [Int: [Int]] = [400: [24678, 5173]]

        let resolved = DevServerCenter.resolve(tracked: tracked, listeners: listeners, parents: parents)
        #expect(resolved == [100: 5173])
    }

    /// Same when two distinct listeners resolve up to the same tracked
    /// ancestor (a server plus a separately spawned watcher, say).
    @Test func picksTheLowestPortAcrossSeparateListenersUnderTheSameAncestor() {
        let tracked: Set<Int> = [100]
        let parents: [Int: Int] = [400: 100, 500: 100]
        let listeners: [Int: [Int]] = [400: [3000], 500: [9229]]

        let resolved = DevServerCenter.resolve(tracked: tracked, listeners: listeners, parents: parents)
        #expect(resolved == [100: 3000])
    }

    @Test func listenerWithNoPathToATrackedPIDIsIgnored() {
        let tracked: Set<Int> = [999]
        let parents: [Int: Int] = [400: 1] // walks straight to PID 1, no tracked ancestor
        let listeners: [Int: [Int]] = [400: [3000]]

        let resolved = DevServerCenter.resolve(tracked: tracked, listeners: listeners, parents: parents)
        #expect(resolved.isEmpty)
    }

    @Test func listenerWithAMissingParentLinkStopsWithoutCrashing() {
        let tracked: Set<Int> = [100]
        let parents: [Int: Int] = [:] // 400's parent is unknown to the table
        let listeners: [Int: [Int]] = [400: [3000]]

        let resolved = DevServerCenter.resolve(tracked: tracked, listeners: listeners, parents: parents)
        #expect(resolved.isEmpty)
    }

    @Test func emptyListenersResolveToNothing() {
        let resolved = DevServerCenter.resolve(tracked: [100], listeners: [:], parents: [:])
        #expect(resolved.isEmpty)
    }

    // MARK: - applyScanResult(pids:resolved:now:)

    /// Counts publications a sink has seen. A reference type so the test can
    /// read the live count; assertions use a delta from `before` so they do
    /// not depend on whether `@Published` replays its current value to a
    /// fresh subscription.
    private final class PublishCounter {
        var value = 0
    }

    /// A fresh, isolated center — no test can pollute another's snapshot —
    /// plus a subscription counting its publications.
    private func trackedCenter() -> (DevServerCenter, PublishCounter, Cancellable) {
        let center = DevServerCenter()
        let counter = PublishCounter()
        let cancellable = center.$servers.sink { _ in counter.value += 1 }
        return (center, counter, cancellable)
    }

    /// The whole point of the single-publication change: one scan resolving
    /// several tabs publishes exactly once, no matter how many PIDs were in
    /// it. The old loop published once per PID.
    @Test func oneScanPublishesOnceEvenForManyPIDs() {
        let (center, counter, cancellable) = trackedCenter()
        defer { cancellable.cancel() }

        let before = counter.value
        let published = center.applyScanResult(
            pids: [100, 200, 300],
            resolved: [100: 3000, 200: 4200, 300: 5173],
            now: Date()
        )
        #expect(published)
        #expect(counter.value - before == 1)
        #expect(center.port(forPID: 100) == 3000)
        #expect(center.port(forPID: 200) == 4200)
        #expect(center.port(forPID: 300) == 5173)
    }

    /// A scan whose ports are unchanged is no news, even though `checkedAt`
    /// advanced: the freshness field is bookkeeping (`scannedAt` serves the
    /// TTL), not something rows draw. Otherwise every scan would publish and
    /// the change-detection would be pure overhead.
    @Test func unchangedPortsPublishNothing() {
        let center = DevServerCenter()

        // The first scan establishes the baseline and must publish.
        #expect(center.applyScanResult(
            pids: [100, 200],
            resolved: [100: 3000, 200: 4200],
            now: .distantPast
        ))

        let (_, counter, cancellable) = trackedCenter()
        defer { cancellable.cancel() }

        // A fresh scan of the same facts is no news — the ports all match.
        let before = counter.value
        let published = center.applyScanResult(
            pids: [100, 200],
            resolved: [100: 3000, 200: 4200],
            now: Date()
        )
        #expect(published == false)
        #expect(counter.value - before == 0)
    }

    /// A tab that stopped being tracked between scans is dropped by the
    /// result — a tab closing must not leave its row drawing a dead port.
    @Test func untrackedPIDIsDropped() {
        let (center, counter, cancellable) = trackedCenter()
        defer { cancellable.cancel() }

        #expect(center.applyScanResult(
            pids: [100, 200],
            resolved: [100: 3000, 200: 4200],
            now: .distantPast
        ))

        let before = counter.value
        let published = center.applyScanResult(
            pids: [200], // 100 went away
            resolved: [200: 4200],
            now: Date()
        )
        #expect(published)
        #expect(counter.value - before == 1)
        #expect(center.port(forPID: 100) == nil)
        #expect(center.port(forPID: 200) == 4200)
    }
}
