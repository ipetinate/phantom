import AppKit
@testable import Ghostty
import Testing

/// The private-API tooltip delay, tested only for the ways it is allowed to
/// fail.
///
/// Nothing here asserts that `NSToolTipManager` exists or that the delay took.
/// The whole point of `ToolTipDelay` is that the day AppKit drops the class the
/// app keeps launching, and a test that demanded the private API be present
/// would go red on exactly that day — turning the graceful path into a build
/// failure. So the private names are only ever passed as the failure cases, and
/// the wrong-signature case is built from public API that will still be there.
@MainActor
struct ToolTipDelayTests {
    /// A class that does not exist yields nil rather than a trap. This is the
    /// path taken if AppKit ever removes `NSToolTipManager` outright.
    @Test func aMissingClassIsAnswerNotACrash() {
        #expect(
            ToolTipDelay.apply(
                delay: 0.4,
                className: "PhantomToolTipManagerThatDoesNotExist",
                sharedName: "sharedToolTipManager",
                setterName: "setInitialToolTipDelay:"
            ) == false
        )
    }

    /// A class that exists without the accessor is the same answer. This is the
    /// path taken if the singleton is reached some other way in a future
    /// release.
    @Test func aMissingSharedAccessorIsAnswerNotACrash() {
        #expect(
            ToolTipDelay.apply(
                delay: 0.4,
                className: "NSProcessInfo",
                sharedName: "phantomSharedThingThatDoesNotExist",
                setterName: "setInitialToolTipDelay:"
            ) == false
        )
    }

    /// A reachable object without the setter is the same answer again. This is
    /// the path taken if the class survives but the delay is no longer settable.
    @Test func aMissingSetterIsAnswerNotACrash() {
        #expect(
            ToolTipDelay.apply(
                delay: 0.4,
                className: "NSProcessInfo",
                sharedName: "processInfo",
                setterName: "phantomSetSomethingThatDoesNotExist:"
            ) == false
        )
    }

    /// A selector that exists with the wrong shape must be refused, not called.
    /// `-description` returns an object and takes no arguments, so calling it
    /// through a pointer typed to take a `Double` would read a register the
    /// caller never wrote. Everything here is public API, so this case stays
    /// meaningful for as long as the file does.
    @Test func aSetterWithTheWrongSignatureIsRefused() {
        #expect(
            ToolTipDelay.apply(
                delay: 0.4,
                className: "NSProcessInfo",
                sharedName: "processInfo",
                setterName: "description"
            ) == false
        )
    }

    /// A non-positive delay is refused before any runtime lookup happens, so
    /// the guard holds whether or not the private API is present.
    @Test func aNonPositiveDelayIsRefused() {
        #expect(ToolTipDelay.apply(delay: 0) == false)
        #expect(ToolTipDelay.apply(delay: -1) == false)
    }

    /// The entry point carries no state, so calling it twice does the same
    /// thing twice and answers the same way. `applicationDidFinishLaunching`
    /// runs once, but a second call must not be a hazard for whoever adds one.
    @Test func callingTheEntryPointTwiceIsHarmless() {
        let first = ToolTipDelay.applyInitialDelay()
        let second = ToolTipDelay.applyInitialDelay()
        #expect(first == second)
    }

    /// The chosen delay has to be shorter than the system's own wait — measured
    /// at 1.5 s on macOS 26 — or the file buys nothing, and long enough that a
    /// pointer crossing a toolbar does not trip it.
    @Test func theDelayIsFasterThanTheSystemAndSlowerThanAPassingPointer() {
        #expect(ToolTipDelay.initialDelay < 1.5)
        #expect(ToolTipDelay.initialDelay >= 0.25)
    }
}
