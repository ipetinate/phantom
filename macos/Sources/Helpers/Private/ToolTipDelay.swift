import AppKit

/// The wait before a tooltip appears, shortened through private AppKit API.
///
/// **This is private API.** `NSToolTipManager` appears in no public header, and
/// neither does its `-setInitialToolTipDelay:`. Nothing public sets that delay:
/// a SwiftUI `.help(_:)` becomes `NSView.toolTip`, and AppKit then shows it on
/// its own schedule, measured at 1.5 s on macOS 26.
///
/// It is worth the private call because this app's tooltips carry facts the
/// reader came for — which branch a merge conflict's "Accept Current" takes,
/// what a git chip counts. A second and a half of holding the pointer still is
/// the reader paying a toll for something the window already knows.
///
/// **When the private API stops existing, nothing happens.** Every step is
/// resolved at run time and checked before it is used: the class, the accessor
/// for the shared manager, the setter, and the setter's exact signature. Any
/// step that fails returns `false` and leaves the system delay in place. There
/// is no crash, no alert, and no other behavior that depends on this.
///
/// **To remove this**, delete this file and its one call in
/// `AppDelegate.applicationDidFinishLaunching`. Nothing else refers to it.
enum ToolTipDelay {
    /// The delay to ask for, in seconds.
    ///
    /// Chosen between two failures. Below roughly a quarter second, tooltips
    /// fire on a pointer that is only crossing the toolbar or the tab strip on
    /// its way somewhere else, so the window flickers with labels nobody asked
    /// for. Above roughly half a second, the pause is long enough to read as a
    /// wait, which is the problem this exists to remove.
    ///
    /// 0.4 s sits above the time a pointer spends over one control while
    /// travelling across a dense row, and below the point where a response
    /// stops feeling like an answer to stopping. It is also a little over a
    /// quarter of the system's 1.5 s, which is a difference the reader notices.
    static let initialDelay: TimeInterval = 0.4

    /// The private names, kept together so a reader can see the whole surface
    /// this depends on in one place.
    private static let managerClassName = "NSToolTipManager"
    private static let sharedManagerName = "sharedToolTipManager"
    private static let setterName = "setInitialToolTipDelay:"

    /// Asks AppKit for `initialDelay`. Returns whether it was applied.
    ///
    /// Safe to call more than once: the call carries the whole state, so a
    /// second call sets the same number again and answers the same way.
    @MainActor
    @discardableResult
    static func applyInitialDelay() -> Bool {
        apply(delay: initialDelay)
    }

    /// The body of `applyInitialDelay`, with the private names as parameters so
    /// a test can drive the failure paths without needing the private API to be
    /// present — or absent.
    @MainActor
    @discardableResult
    static func apply(
        delay: TimeInterval,
        className: String = managerClassName,
        sharedName: String = sharedManagerName,
        setterName: String = setterName
    ) -> Bool {
        /// A tooltip that appears with no wait at all is the crossing-the-
        /// toolbar failure at its worst, and a negative wait has no meaning.
        /// Neither is worth handing to a method whose behavior is undocumented.
        guard delay > 0 else { return false }

        guard let managerClass = NSClassFromString(className) else { return false }
        guard let manager = object(fromClassMethod: sharedName, on: managerClass) else { return false }
        guard let managerType = object_getClass(manager) else { return false }
        guard let setter = doubleSetter(named: setterName, on: managerType) else { return false }

        setter(manager, NSSelectorFromString(setterName), delay)
        return true
    }

    // MARK: - Runtime resolution

    /// The object returned by a zero-argument class method, or nil when the
    /// method is missing or does not return an object.
    ///
    /// The implementation is called through an `Unmanaged` return so ownership
    /// stays explicit: an accessor for a shared instance returns it unretained,
    /// and letting Swift guess that would be a retain the caller never balances.
    private static func object(fromClassMethod name: String, on cls: AnyClass) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        guard hasSignature(method, returning: "@", arguments: []) else { return nil }

        typealias Accessor = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let accessor = unsafeBitCast(method_getImplementation(method), to: Accessor.self)
        guard let result = accessor(cls as AnyObject, selector) else { return nil }
        return result.takeUnretainedValue()
    }

    /// A function that calls an instance method taking one `Double` and
    /// returning nothing, or nil when no such method exists on the class.
    private static func doubleSetter(
        named name: String,
        on cls: AnyClass
    ) -> (@convention(c) (AnyObject, Selector, Double) -> Void)? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, selector) else { return nil }
        guard hasSignature(method, returning: "v", arguments: ["d"]) else { return nil }

        typealias Setter = @convention(c) (AnyObject, Selector, Double) -> Void
        return unsafeBitCast(method_getImplementation(method), to: Setter.self)
    }

    /// Whether a method returns `expectedReturn` and takes exactly
    /// `expectedArguments` after the implicit `self` and `_cmd`.
    ///
    /// This is the check that makes calling an implementation through a cast
    /// function pointer defensible. A future AppKit that keeps the selector but
    /// takes an `NSNumber`, or a `Float`, would otherwise read whichever
    /// register the argument was not written to.
    private static func hasSignature(
        _ method: Method,
        returning expectedReturn: String,
        arguments expectedArguments: [String]
    ) -> Bool {
        guard method_getNumberOfArguments(method) == UInt32(2 + expectedArguments.count) else {
            return false
        }
        guard encoding(method_copyReturnType(method)) == expectedReturn else { return false }

        for (offset, expected) in expectedArguments.enumerated() {
            let actual = encoding(method_copyArgumentType(method, UInt32(2 + offset)))
            guard actual == expected else { return false }
        }
        return true
    }

    /// Reads a type encoding the runtime allocated for us, and frees it.
    private static func encoding(_ buffer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let buffer else { return nil }
        defer { free(buffer) }
        return String(cString: buffer)
    }
}
