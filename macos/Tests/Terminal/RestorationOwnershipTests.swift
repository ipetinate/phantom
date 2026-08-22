import Testing
import AppKit
@testable import Ghostty

/// Pins the one answer to "who restores a terminal window".
///
/// The launch path is the worst place in the app to be wrong twice, and it
/// was: two mechanisms rebuilding the same session, neither aware of the
/// other. That the store restores is covered by `PhantomSessionStoreTests`;
/// what is covered here is that the other one cannot, whatever a saved-state
/// bundle written by an older build still asks for — and that the reader's
/// switch still outranks the owner.
@Suite
struct RestorationOwnershipTests {
    private static var terminalIdentifier: NSUserInterfaceItemIdentifier {
        .init(String(describing: TerminalWindowRestoration.self))
    }

    /// The completion handler is called synchronously on every path that can
    /// be reached without a window server, so the answer reads straight back.
    @MainActor
    private func restore(
        identifier: NSUserInterfaceItemIdentifier
    ) -> (called: Bool, window: NSWindow?, error: Error?) {
        var called = false
        var window: NSWindow?
        var error: Error?
        TerminalWindowRestoration.restoreWindow(
            withIdentifier: identifier,
            state: NSCoder()
        ) { restored, failure in
            called = true
            window = restored
            error = failure
        }
        return (called, window, error)
    }

    /// No window, and no error either: AppKit is being asked to forget the
    /// window, not told that restoring it broke.
    @MainActor
    @Test func macOSRestorationProducesNoTerminalWindow() {
        let result = restore(identifier: Self.terminalIdentifier)

        #expect(result.called)
        #expect(result.window == nil)
        #expect(result.error == nil)
    }

    @MainActor
    @Test func anIdentifierFromSomethingElseIsRefused() {
        let result = restore(identifier: .init("SomeOtherWindow"))

        var refused = false
        if case .identifierUnknown? = result.error as? TerminalRestoreError { refused = true }

        #expect(result.called)
        #expect(result.window == nil)
        #expect(refused)
    }

    // MARK: - The switch outranks the owner

    /// "Restore Windows on Launch" off has to mean nothing comes back. With
    /// the store as the only restorer, this predicate is the whole of that
    /// promise on its side.
    @Test func neverStopsTheStoreRestoring() {
        #expect(!PhantomSessionStore.mayRestore(windowSaveState: "never"))
    }

    /// Everything that is not `never` restores, and the list matters: the
    /// settings toggle used to write `default`, a value every reader compared
    /// against `always` and ignored, and an unreadable config answers with the
    /// empty string. Both have to mean yes, or the switch reads as off while
    /// showing on.
    @Test(arguments: ["always", "default", ""])
    func everythingElseRestores(_ value: String) {
        #expect(PhantomSessionStore.mayRestore(windowSaveState: value))
    }

    // MARK: - A closed window is not a terminal to come back to

    /// The case the closed term exists for: a window that was closed while
    /// something still held its controller can be ordered front again — the
    /// Dock's window list does exactly that — and from then on it is visible.
    /// Counting it is what makes the next Dock click decide the session is
    /// already up and restore nothing.
    @Test func aClosedWindowShownAgainIsNotAReachableTerminal() {
        #expect(!PhantomSessionStore.isReachableTerminal(
            hasClosed: true, isVisible: true, isMiniaturized: false))
    }

    @Test func anOpenWindowOnScreenIsReachable() {
        #expect(PhantomSessionStore.isReachableTerminal(
            hasClosed: false, isVisible: true, isMiniaturized: false))
    }

    /// The Dock counts: a session minimized to it is one the reader can get
    /// back to, and restoring over it would double their terminals.
    @Test func aMinimizedWindowIsReachable() {
        #expect(PhantomSessionStore.isReachableTerminal(
            hasClosed: false, isVisible: false, isMiniaturized: true))
    }

    /// A window that exists and has never been shown — one the restore is
    /// still placing — is not something the reader can reach, which is what
    /// lets a launch tell a blank New Window to stand down.
    @Test func aWindowThatWasNeverShownIsNotReachable() {
        #expect(!PhantomSessionStore.isReachableTerminal(
            hasClosed: false, isVisible: false, isMiniaturized: false))
    }
}
