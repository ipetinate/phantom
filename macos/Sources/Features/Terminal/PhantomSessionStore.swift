import AppKit
import Foundation

/// The facts about a saved terminal the store reasons about, apart from the
/// surface tree it exists to carry.
///
/// A `TerminalRestorableState` cannot be constructed in a test: decoding one
/// reaches `Ghostty.SurfaceView.init(from:)`, which builds a live libghostty
/// surface and spawns a login shell — inside the test host, which *is*
/// Phantom.app. Stating the handful of fields the grouping and geometry
/// decisions read as a protocol lets those decisions be tested against a
/// value that is nothing but those fields.
protocol PhantomSessionState {
    var tabGroupID: Int? { get }
    var tabIndex: Int? { get }
    var isSelectedTab: Bool? { get }
    var frame: CGRect? { get }
    var effectiveFullscreenMode: FullscreenMode? { get }
    var isFullscreen: Bool? { get }
}

extension TerminalRestorableState: PhantomSessionState {}

/// Phantom's own terminal session persistence.
///
/// macOS window restoration is the app's nominal restore mechanism, but it
/// is famously unreliable: when windows are closed and reopened within a
/// session, macOS has been observed to restore only one or two of the
/// windows that were open at quit time, silently dropping the rest.
/// Ghostty upstream documents this as an unfixable macOS behavior and plans
/// to move to its own session persistence.
///
/// This store is that persistence. It mirrors every open terminal window
/// (surface trees, working directories, frames, tab colors, title
/// overrides) to a file and, on launch, restores from it instead of
/// trusting macOS's saved state. It is the only thing that restores a
/// terminal window — see `ownsTerminalRestoration`.
final class PhantomSessionStore {
    static let shared = PhantomSessionStore()

    /// This store, and nothing else, brings a terminal window back.
    ///
    /// Both were live: AppKit re-created the windows it had seen at quit
    /// while this store rebuilt the same session from its own file, and
    /// neither knew about the other. The stand-down added for that asked
    /// whether this store *happened* to have a session on disk at the moment
    /// AppKit got round to asking — an answer that depends on the file's
    /// contents and on which of the two ran first, so "only one of them
    /// acts" held by arithmetic rather than by construction.
    ///
    /// The decision is made here instead, once, and read by both places that
    /// could let AppKit act: `TerminalController.windowDidLoad`, which no
    /// longer registers a terminal window for restoration at all, and
    /// `TerminalWindowRestoration.restoreWindow`, which declines whatever a
    /// saved-state bundle written by an older build still asks for.
    ///
    /// This store wins because it is the only one that *can*: it knows the
    /// worktree a terminal belongs to, the agent session running in it, its
    /// sidebar group and its editor, none of which AppKit can reconstruct
    /// from a window. What AppKit knew and this store does not is where a
    /// window physically was — its Space and its display. A restored window
    /// keeps its frame, its tab group, its tab order and which tab was
    /// showing, and opens on whichever Space the reader is on.
    ///
    /// This does not overrule `window-save-state`. `never` still means
    /// nothing comes back from either: this store refuses in
    /// `restoreIfNeeded`, and AppKit is told to keep no windows at all
    /// (`NSQuitAlwaysKeepsWindows`, in `AppDelegate`).
    static let ownsTerminalRestoration = true

    /// While restoring from the store, saves are suspended so a partial
    /// window set can never overwrite the saved session.
    ///
    /// Read (never written) outside this type by `SidebarTabManager`, which
    /// consults it to skip seeding a just-created window's sidebar from
    /// whichever window happens to be key — see `SidebarTabManager.shouldSeed`
    /// for why that heuristic cannot be trusted while a restore is placing
    /// windows of its own.
    private(set) var isRestoring = false

    /// Whether the app has begun quitting.
    ///
    /// This is the term `saveNow` was missing, and the reason it could eat a
    /// session on the way down: **a window that went away because the reader
    /// closed it and a window that went away because quitting took it are the
    /// same window to every predicate here.** Both are gone from `isOpen`, and
    /// the first has to shrink the session while the second must never.
    /// Nothing about the window can tell them apart, so the answer has to come
    /// from what the app is doing — and only the app knows that.
    ///
    /// Measured, on the Review Windows path, with ten terminals open: the
    /// review closes them one at a time, each close schedules a save, and each
    /// save lands between two closes and writes what is left. Nine, eight,
    /// seven, six, five, four — one entry lost per window reviewed, all of it
    /// on the way to a quit the reader expected to come back from. Whether the
    /// last save is the empty one that `shouldWrite` refuses is pure timing:
    /// finish the review and the session survives by luck, stop half way and
    /// the file keeps the half.
    ///
    /// Set from the moment the app is asked whether it may quit until it dies
    /// or the quit is called off. Should a cancelled quit ever fail to clear
    /// it, the cost is a session that stops shrinking — closed windows come
    /// back — which is the direction to be wrong in.
    /// Readable, because it answers a second question too: `TabStateCenter`
    /// asks it to tell an agent the reader quit apart from one this quit is
    /// about to kill. Both are `ended` on disk and only the app knows which is
    /// which — the same reason this flag exists at all.
    private(set) var isQuitting = false

    /// The app has been asked to quit. Until it dies or `quitWasCancelled` is
    /// called, no save may record fewer terminals than the session already has.
    func quitBegan() {
        isQuitting = true
    }

    /// The quit was called off and the reader is using the app again, so their
    /// window set means what it says once more.
    ///
    /// A save follows, because a quit can be called off part way through:
    /// cancelling a review after answering for three of ten windows leaves
    /// seven, and the refusals along the way mean the file still says ten. The
    /// windows the reader agreed to close on the way out are closed either
    /// way, and without this they would come back at the next launch.
    func quitWasCancelled() {
        isQuitting = false
        scheduleSave()
    }

    /// True when this process is a test host rather than the app someone is
    /// using.
    ///
    /// The tests run *inside* Phantom.app, so without this the suite plays
    /// the whole session lifecycle against the real file: launch restores
    /// the user's actual windows — spawning their shells, and resuming
    /// their agent sessions — and termination writes whatever the test host
    /// happened to have open back over it. A test run would quietly replace
    /// the session someone left behind.
    private static let isRunningTests: Bool = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    /// Membership changes arrive in bursts (a window close, a tab open, a
    /// macOS restore); only the final state matters.
    ///
    /// Long enough to outlast a whole window closing. A window's tabs close
    /// one at a time, each announcing itself, and at 0.4s the burst outran
    /// the coalescing: the saves landed one per tab and ate the session on
    /// the way down — three terminals recorded as three, then two, then
    /// one, so "closed the window" left a session of one. Waiting for the
    /// teardown to finish means the save that lands sees no windows at all,
    /// which is the case the guard in `saveNow` refuses to write. Nothing is
    /// lost by waiting: termination saves synchronously.
    private static let saveDebounce: TimeInterval = 1.5

    private init() {
        fileURL = Self.defaultFileURL()
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "com.ipetinate.phantom",
                isDirectory: true
            )
            .appendingPathComponent("session.json")
    }

    // MARK: Which Windows Count

    /// Whether a window is one of the session's windows: on screen, or in
    /// the Dock.
    ///
    /// The obvious spelling of "is anything open" is
    /// `TerminalController.all.isEmpty`, and it is the wrong one. That list
    /// is derived from `NSApp.windows`, and AppKit keeps a closed window in
    /// there until it is released — a window controller holds one well past
    /// its close. Measured right after closing every window: ten controllers
    /// still listed, twelve windows in the app. Asking it whether anything is
    /// open answers yes forever after the first close, so the session was
    /// never restored and a blank window was opened over the top of it
    /// instead.
    ///
    /// `isVisible` was the next attempt and it was wrong too, because it is
    /// false for a window in the Dock and nothing about it separates
    /// minimized from closed. `isVisible || isMiniaturized` was the third,
    /// and it was wrong in a way that only showed up in use: **a background
    /// tab does not reliably report `isVisible`**. An earlier version of this
    /// comment claimed it did. It does not, and the claim was never measured.
    ///
    /// This is the table, from a probe that builds real windows, groups them,
    /// minimizes, closes and reads the properties back:
    ///
    /// | state                     | isVisible | isMiniaturized | tabGroup |
    /// |---------------------------|-----------|----------------|----------|
    /// | shown, alone              | true      | false          | nil      |
    /// | selected tab of a group   | true      | false          | set      |
    /// | background tab            | **either**| false          | set      |
    /// | any tab, group minimized  | false     | true           | set      |
    /// | closed                    | false     | false          | **nil**  |
    ///
    /// Two rows carry the answer. Background tabs disagree with each other —
    /// one reported `true` and its neighbour `false` in the same group — so
    /// no reading of `isVisible` can include them all. And a closed window's
    /// `tabGroup` is nil, which is what makes group membership safe to trust:
    /// it says "alive and in a window" without letting a released window back
    /// in.
    ///
    /// What each mistake cost, in order: counting controllers meant the
    /// session was never restored and a blank window opened over it. Reading
    /// only `isVisible` dropped a minimized window and every tab in it, and
    /// claimed nothing was open when everything was in the Dock — restoring
    /// the session on top of itself, two tabs to a conversation. Missing
    /// background tabs collapsed the file to the one selected tab: a restore
    /// scheduled a save, the save saw one window of four, and the next
    /// reopen brought back a single terminal. Every restore quietly threw the
    /// rest of the session away.
    ///
    /// The fourth mistake was believing one predicate could answer both, and
    /// it is the reason this comment is long. **These are two questions.**
    ///
    /// *What should the session record?* Every window the reader still has,
    /// background tabs included — a tab they cannot see right now is one
    /// they expect back tomorrow. That needs the group term.
    ///
    /// *Is anything open?* Whether the reader can reach a window at all,
    /// which decides if New Window and a Dock click restore or open blank.
    /// That must **not** use the group term: after a window closes, its tabs
    /// linger in `NSApp.windows` long enough to still answer yes, and a yes
    /// there means the reopen does nothing at all — the Dock lists the
    /// terminals, clicking the icon produces no window, and the app looks
    /// wedged. Reachability is about the screen and the Dock, and nothing
    /// else.
    ///
    /// Spelled over booleans rather than over `NSWindow` so both can be
    /// exercised without a window server, and with explicit arguments and no
    /// defaults, because a predicate wrong this many times should not let a
    /// caller silently forget a term.
    static func isPartOfSession(
        isVisible: Bool,
        isMiniaturized: Bool,
        isInTabGroup: Bool
    ) -> Bool {
        isVisible || isMiniaturized || isInTabGroup
    }

    /// Whether the reader can reach this window: on screen, or in the Dock.
    /// See `isPartOfSession` for why this deliberately ignores tab-group
    /// membership.
    static func isReachable(isVisible: Bool, isMiniaturized: Bool) -> Bool {
        isVisible || isMiniaturized
    }

    /// Whether a window is still part of the session. See `isPartOfSession`.
    static func isOpen(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return isPartOfSession(
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isInTabGroup: window.tabGroup != nil)
    }

    /// Whether the reader can reach this window. See `isReachable`.
    static func isReachable(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return isReachable(
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized)
    }

    /// Whether the reader can reach any terminal window at all — one on
    /// screen, or one in the Dock.
    ///
    /// Named for reachability rather than for being "open" on purpose: the
    /// ambiguity of *open* is what put the wrong predicate here. This decides
    /// whether New Window and a Dock click restore the session or open a
    /// blank window, so it must answer no the moment the reader has nothing
    /// left to look at — including while the tabs of a just-closed window are
    /// still listed in `NSApp.windows`. Answering yes there is what made the
    /// Dock icon do nothing while its menu still listed every terminal.
    ///
    /// Deliberately **not** the predicate the save filter uses. See
    /// `isPartOfSession`.
    static var hasReachableTerminalWindows: Bool {
        TerminalController.all.contains {
            isReachableTerminal(
                hasClosed: $0.hasClosed,
                isVisible: $0.window?.isVisible ?? false,
                isMiniaturized: $0.window?.isMiniaturized ?? false)
        }
    }

    /// Whether a terminal counts as one the reader can still get back to.
    ///
    /// The closed term is not redundant with the other two. A window that was
    /// closed while something held its controller can be *shown again* —
    /// picking it out of the Dock's window list does exactly that — and from
    /// then on it reports `isVisible`, so reachability alone says the reader
    /// has a terminal. They do not: they have a husk (see
    /// `BaseTerminalController.hasClosed`). Counting it is worse than cosmetic
    /// — it is what makes the next Dock click decide the session is already up
    /// and restore nothing, leaving the reader with a bare frame and their
    /// terminals still on disk.
    static func isReachableTerminal(
        hasClosed: Bool,
        isVisible: Bool,
        isMiniaturized: Bool
    ) -> Bool {
        !hasClosed && isReachable(isVisible: isVisible, isMiniaturized: isMiniaturized)
    }

    // MARK: The Session File

    /// The session as it is written: the states, and the version of the
    /// shape they are written in.
    ///
    /// The states used to be the entire file — a bare JSON array — which
    /// left nothing to say which shape they were in. That is a trap with a
    /// long fuse: the day a non-optional field is added to `InternalState`,
    /// every `session.json` already on disk stops decoding, and it did so
    /// silently (the save logs, the load did not). The reader would open the
    /// app to a blank window, and the next save would write `[]` over the
    /// session they had just lost. A version in the file makes a shape this
    /// build cannot read *recognizable* as such, and the rule for one is to
    /// leave it alone.
    private struct Envelope: Codable {
        let version: Int
        let states: [TerminalRestorableState]
    }

    /// The envelope version this build writes. A file with no version at all
    /// is the original bare array, and is read as such.
    static let fileVersion = 1

    /// What the session file holds, learned without decoding it.
    enum SavedSession: Equatable {
        /// No session has been written, or the file is gone.
        case absent

        /// A file this build understands, holding `count` terminals.
        /// `isVersioned` separates the current envelope from the original
        /// bare array.
        case readable(count: Int, isVersioned: Bool)

        /// A file this build cannot make sense of: malformed, or written by
        /// a newer Phantom. A session we cannot read is still a session —
        /// the reader may be one launch away from the build that reads it —
        /// so this is never overwritten by a save that has nothing to say.
        case unreadable
    }

    /// How many terminals the session file holds, and in which shape,
    /// without decoding a single one of them.
    ///
    /// This exists because `load` is destructive. The guard in `saveNow`
    /// only ever wanted the count, and was paying a full decode for it — as
    /// was the query that used to be asked once per window in macOS's *own*
    /// saved state, where eight saved terminals across three macOS windows
    /// meant twenty-four surfaces, and twenty-four login shells, created and
    /// thrown away on the launch path before the real restore had begun.
    /// Each of those surfaces also fires the agent resume, into a shell
    /// nothing will ever show.
    ///
    /// `JSONSerialization` walks the same bytes and hands back arrays and
    /// dictionaries, so counting costs a parse and nothing more.
    static func inspect(_ data: Data) -> SavedSession {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return .unreadable
        }

        if let states = json as? [Any] {
            return .readable(count: states.count, isVersioned: false)
        }

        guard let envelope = json as? [String: Any],
              let version = envelope["version"] as? Int,
              let states = envelope["states"] as? [Any],
              version <= fileVersion else {
            return .unreadable
        }
        return .readable(count: states.count, isVersioned: true)
    }

    /// The surface ids the saved session still refers to.
    ///
    /// Exists for callers that need to know whether a per-surface file on
    /// disk still belongs to a terminal that is coming back. The tab-state
    /// prune is the one that does, and age cannot answer it: an mtime
    /// records the last time an *agent* wrote, not the last time the *tab*
    /// was used, so a tab left open while its agent stayed quiet ages out
    /// while still being part of the session. Losing that file loses the
    /// session id, and the tab returns as a bare shell without even trying
    /// to resume.
    ///
    /// Harvested from the raw JSON rather than from decoded states, for the
    /// same reason `inspect` exists: decoding reaches
    /// `SurfaceView.init(from:)`, which builds a live surface and forks a
    /// shell. Every surface carries its id under a `uuid` key — including
    /// the ones nested inside a split tree — so collecting that one key
    /// covers the whole arrangement while instantiating none of it.
    ///
    /// `focusedSurface` is deliberately not collected: it always repeats an
    /// id that a `uuid` key has already supplied, and harvesting keys that
    /// merely *hold* an id rather than *define* one would make the set grow
    /// with every future field that happens to reference a surface.
    static func surfaceIDs(in data: Data) -> Set<UUID> {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var ids: Set<UUID> = []
        collect(surfaceIDsFrom: json, into: &ids, depth: 0)
        return ids
    }

    /// Bounded because this walks a file the user can edit and that outlives
    /// any single build: a pathological nesting depth must cost a truncated
    /// answer, not the stack. Real arrangements nest a handful of levels — a
    /// split tree of thirty-two panes is six — so the ceiling is far above
    /// anything the app writes.
    private static let maxSurfaceIDDepth = 64

    private static func collect(
        surfaceIDsFrom json: Any,
        into ids: inout Set<UUID>,
        depth: Int
    ) {
        guard depth < maxSurfaceIDDepth else { return }

        switch json {
        case let dictionary as [String: Any]:
            if let raw = dictionary["uuid"] as? String, let id = UUID(uuidString: raw) {
                ids.insert(id)
            }
            for value in dictionary.values {
                collect(surfaceIDsFrom: value, into: &ids, depth: depth + 1)
            }
        case let array as [Any]:
            for value in array {
                collect(surfaceIDsFrom: value, into: &ids, depth: depth + 1)
            }
        default:
            return
        }
    }

    /// The ids in the session file as it stands on disk, or an empty set
    /// when there is nothing readable there.
    ///
    /// An empty set means "this tells you nothing", never "nothing is
    /// referenced" — a caller pruning against it must treat emptiness as a
    /// reason to fall back on its own horizon rather than as permission to
    /// delete everything.
    static var referencedSurfaceIDs: Set<UUID> {
        guard let data = try? Data(contentsOf: defaultFileURL()) else { return [] }
        return surfaceIDs(in: data)
    }

    /// What is on disk right now, or `.absent` when there is no file.
    private func savedSession() -> SavedSession {
        guard let data = try? Data(contentsOf: fileURL) else { return .absent }
        return Self.inspect(data)
    }

    /// Whether a save holding `stateCount` terminals may replace `existing`.
    ///
    /// Having no windows is not the same as having no session. Closing the
    /// last window leaves the app running with nothing open, and recording
    /// that erased the very thing the next window should come back to — the
    /// session was gone before anything could restore it. An empty set is
    /// therefore never written over a session that has something in it; the
    /// last real arrangement stands until another real one replaces it. A
    /// file we cannot read counts as having something in it, so a decode
    /// failure cannot compound into an erased session.
    ///
    /// A *shorter* set does replace a longer one while the reader is using
    /// the app, deliberately: closing one of three windows has to leave a
    /// session of two, or a session could only ever grow. What made short
    /// saves dangerous was the window predicate quietly dropping minimized
    /// windows, and that is fixed where it belongs, in `isOpen`.
    ///
    /// `mayShrink` is the caller saying whether a shorter set means what it
    /// says. It does while the app is running: the reader closed something.
    /// It does not once the app is quitting, because the windows disappearing
    /// then are the quit taking them, not the reader giving them up — see
    /// `isQuitting` for the measurement. Passed rather than read from the
    /// store so the rule stays a question about two numbers, answerable
    /// without an app to be quitting.
    static func shouldWrite(
        stateCount: Int,
        over existing: SavedSession,
        mayShrink: Bool
    ) -> Bool {
        if !mayShrink,
           case .readable(let count, _) = existing,
           stateCount < count {
            return false
        }

        if stateCount > 0 { return true }

        switch existing {
        case .absent:
            return true
        case .readable(let count, _):
            return count == 0
        case .unreadable:
            return false
        }
    }

    /// Decodes the saved session.
    ///
    /// - Warning: this does not read the session, it *builds* it. The states'
    ///   surface trees decode into `Ghostty.SurfaceView`s, and
    ///   `SurfaceView.init(from:)` reaches for the live `ghostty.app`, calls
    ///   `ghostty_surface_new` and fires the agent resume: a real terminal,
    ///   a real login shell, a real conversation resumed, per saved surface.
    ///   Decoding is instantiating. Only `restoreIfNeeded` may call this, and
    ///   only because it puts every surface it gets into a window. Anything
    ///   that wants to know *about* the session wants `inspect`.
    private func load() -> [TerminalRestorableState]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        /// The shape is settled before decoding, never by trying one decode
        /// and falling back to the other: a decode of the wrong shape can get
        /// far enough to build surfaces before it throws.
        let shape = Self.inspect(data)
        do {
            switch shape {
            case .absent:
                return nil

            case .unreadable:
                Ghostty.logger.error(
                    "session load skipped: file is malformed or newer than this build; leaving it alone"
                )
                return nil

            case .readable(_, let isVersioned):
                if isVersioned {
                    return try JSONDecoder().decode(Envelope.self, from: data).states
                }
                return try JSONDecoder().decode([TerminalRestorableState].self, from: data)
            }
        } catch {
            Ghostty.logger.error(
                "session load failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: Saving

    /// Re-reads the open terminal windows and writes the session file,
    /// debounced. A single call per burst; cancelled work items never run.
    func scheduleSave() {
        guard !isRestoring, !Self.isRunningTests else { return }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    /// Synchronous, authoritative save. Used at termination and when the
    /// debounced save fires.
    func saveNow() {
        guard !isRestoring, !Self.isRunningTests else { return }

        // Windows sharing a tab group are tabs of one window; record the
        // group membership and in-group order so the restore can re-form
        // tabs instead of producing separate windows.
        var groupIDByTabGroup: [ObjectIdentifier: Int] = [:]
        var nextGroupID = 0

        let states = TerminalController.all.compactMap { controller -> TerminalRestorableState? in
            /// Only the windows that are still part of the session — on
            /// screen or in the Dock. A closed window lingers in
            /// `NSApp.windows` until it is released, and recording those
            /// wrote the same terminals back into the session over and over
            /// — as *standalones*, since a closed window has no tab group —
            /// so the file grew every cycle and restored a pile of separate
            /// windows that had been tabs. Measured: eight terminals became
            /// twenty-two entries in a handful of open/close rounds. See
            /// `isOpen` for why the Dock has to be in the question too.
            guard let window = controller.window, Self.isOpen(window) else { return nil }

            var tabGroupID: Int?
            var tabIndex: Int?
            var isSelectedTab: Bool?
            if let group = window.tabGroup, group.windows.count > 1 {
                let key = ObjectIdentifier(group)
                if let existing = groupIDByTabGroup[key] {
                    tabGroupID = existing
                } else {
                    tabGroupID = nextGroupID
                    groupIDByTabGroup[key] = nextGroupID
                    nextGroupID += 1
                }
                tabIndex = group.windows.firstIndex(of: window)

                /// Which tab the window was *showing*, which no position in
                /// `group.windows` implies: that array is tab-bar order and
                /// `selectedWindow` is a property of its own. Recording only
                /// the order is why a window of four tabs came back on the
                /// first one however far along the reader had been working.
                isSelectedTab = group.selectedWindow === window
            }

            return TerminalRestorableState(
                from: controller,
                tabGroupID: tabGroupID,
                tabIndex: tabIndex,
                isSelectedTab: isSelectedTab)
        }

        guard Self.shouldWrite(
            stateCount: states.count,
            over: savedSession(),
            mayShrink: !isQuitting
        ) else { return }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(
                Envelope(version: Self.fileVersion, states: states))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Ghostty.logger.error(
                "session save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: Restoring

    /// Whether "Restore Windows on Launch" allows a restore at all.
    ///
    /// Off means nothing comes back, from either mechanism — this store here,
    /// and AppKit through `NSQuitAlwaysKeepsWindows` in `AppDelegate`. Now
    /// that this store is the only restorer of terminals
    /// (`ownsTerminalRestoration`), this is the only place left where the
    /// switch can be honoured, so it is spelled over the value rather than
    /// read inline: the setting used to be written as `default`, which every
    /// reader ignored, and only `never` may ever mean no.
    static func mayRestore(windowSaveState: String) -> Bool {
        windowSaveState != "never"
    }

    /// Restores the saved session. No-op when windows are already open or
    /// when the saved session is empty.
    ///
    /// Called at launch before the app would otherwise open a default
    /// window, and again wherever a window is asked for while none exist —
    /// quitting is not the only way to end up with nothing open, and a
    /// session is worth as much after closing the last window as it is
    /// after a relaunch.
    ///
    /// - Returns: whether it produced any windows, so a caller that would
    ///   otherwise open an empty one can stand down.
    @discardableResult
    func restoreIfNeeded() -> Bool {
        guard !isRestoring, !Self.isRunningTests else { return false }

        // Respect the explicit "never restore" choice, matching the check
        // macOS restoration performs.
        let saveState = (NSApplication.shared.delegate as? AppDelegate)?
            .ghostty.config.windowSaveState ?? ""
        guard Self.mayRestore(windowSaveState: saveState) else { return false }

        // If windows are already up there is nothing for us to do, and
        // creating more would duplicate them. This is also what keeps a
        // second New Window from restoring the session again: once the
        // first one brought it back, windows are on screen.
        guard !Self.hasReachableTerminalWindows else { return false }

        guard let states = load(), !states.isEmpty else { return false }
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return false }

        WindowBreadcrumbs.note(
            "restore: beginning with \(states.count) states in " +
            "\(Set(states.map(\.tabGroupID)).count) groups")

        isRestoring = true
        defer {
            isRestoring = false
            scheduleSave()
        }

        var (groups, standalones) = Self.partition(states)

        /// With the sidebar on, one group is the shape of the app: every
        /// terminal is a row of the same list, and a second window is not
        /// something any supported gesture produces — the ways one used to
        /// appear (⌘N routed to a loose window, a tab request degrading
        /// when its parent was a husk) were all bugs, and the store then
        /// preserved their output: a session saved as two groups restored
        /// as two groups on every launch after, which is how one accident
        /// became a permanent ghost. Merging here is what heals those
        /// files. Without the sidebar the split is upstream's normal
        /// multi-window world and is restored as written.
        if appDelegate.ghostty.config.sidebar {
            if groups.count + standalones.count > 1 {
                WindowBreadcrumbs.note(
                    "restore: merging \(groups.count) groups and "
                    + "\(standalones.count) standalones into one")
            }
            (groups, standalones) = Self.unified(groups: groups, standalones: standalones)
        }

        var restoredCount = 0
        for group in groups {
            restoredCount += restoreWindows(in: group, appDelegate: appDelegate)
        }
        for state in standalones {
            restoredCount += restoreWindows(in: [state], appDelegate: appDelegate)
        }

        /// What this restore actually produced, not what the app happens to
        /// hold. `TerminalController.all` is the count that cannot say no
        /// (see `isOpen`), and reporting success from it meant that a restore
        /// which produced nothing still told New Window to stand down — so
        /// New Window opened nothing, and went on opening nothing.
        return restoredCount > 0
    }

    /// One group holding every state, in group-then-standalone order — the
    /// shape `restoreIfNeeded` uses when the sidebar is on. Pure, because the
    /// merge policy is the piece of the healing that has to hold without an
    /// app: a session file carrying an accidental split must come back whole.
    static func unified<State: PhantomSessionState>(
        groups: [[State]],
        standalones: [State]
    ) -> (groups: [[State]], standalones: [State]) {
        let merged = groups.flatMap { $0 } + standalones
        guard !merged.isEmpty else { return ([], []) }
        return ([merged], [])
    }

    /// Splits saved states into the windows that were tabs of one window and
    /// the windows that stood alone.
    ///
    /// States that were tabs of the same window carry the same `tabGroupID`;
    /// a `nil` id was a window of its own. Group order follows first
    /// appearance in the file so a restore is deterministic.
    static func partition<State: PhantomSessionState>(
        _ states: [State]
    ) -> (groups: [[State]], standalones: [State]) {
        var groupIndexByID: [Int: Int] = [:]
        var groups: [[State]] = []
        var standalones: [State] = []

        for state in states {
            guard let id = state.tabGroupID else {
                standalones.append(state)
                continue
            }
            if let index = groupIndexByID[id] {
                groups[index].append(state)
            } else {
                groupIndexByID[id] = groups.count
                groups.append([state])
            }
        }

        return (groups, standalones)
    }

    /// One group's states in tab-bar order.
    ///
    /// A state with no recorded position sorts last rather than first: an
    /// unpositioned tab is one we know nothing about, and putting it at the
    /// front would move the tabs we *do* know about.
    static func ordered<State: PhantomSessionState>(_ group: [State]) -> [State] {
        group.sorted { lhs, rhs in
            (lhs.tabIndex ?? .max) < (rhs.tabIndex ?? .max)
        }
    }

    /// Which of an ordered group was the tab the window was showing, if the
    /// session recorded one at all. `nil` for sessions written before the
    /// selection was persisted, which the restore reads as "the first tab".
    static func selectedIndex<State: PhantomSessionState>(in ordered: [State]) -> Int? {
        ordered.firstIndex { $0.isSelectedTab == true }
    }

    /// The frame to give a restored window, if any.
    ///
    /// A window that was in fullscreen has the fullscreen bounds for a
    /// frame, and putting those on a windowed window produces a giant,
    /// broken-looking thing. Everything else gets the frame it was left at —
    /// which is most windows, and which they were not getting: the condition
    /// used to be `effectiveFullscreenMode != .native`, and that mode reads
    /// `.native` for every window ever opened whether or not it was ever
    /// fullscreen (see `InternalState.isFullscreen`). So the common case —
    /// an ordinary window, of tabs or not — came back at a default size
    /// wherever macOS felt like putting it.
    static func restoredFrame<State: PhantomSessionState>(for state: State) -> CGRect? {
        state.isFullscreen == true ? nil : state.frame
    }

    /// The fullscreen mode to put a restored window into, if any.
    ///
    /// Only a window that actually *was* in fullscreen goes back into it.
    /// Toggling on the strength of `effectiveFullscreenMode` alone, as this
    /// did, put every restored window into native fullscreen, because that
    /// mode is set for every window at load time and means no more than
    /// "the mode fullscreen would use here".
    static func restoredFullscreenMode<State: PhantomSessionState>(
        for state: State
    ) -> FullscreenMode? {
        state.isFullscreen == true ? state.effectiveFullscreenMode : nil
    }

    /// Creates the controllers for the states of one window (a tab group's
    /// members or a standalone window) and joins them into a tab group.
    ///
    /// Tabs must join the group *before* any window is shown — AppKit
    /// refuses to re-group a window that is already on screen, which is what
    /// turned restored tabs into separate windows. The first tab in the bar
    /// anchors the group and carries its geometry; which tab the window was
    /// *showing* is a separate question, recorded as `isSelectedTab`, and
    /// that tab is the one brought forward once the group has formed.
    ///
    /// - Returns: how many windows it produced, so the caller can tell a
    ///   restore that put something on screen from one that did not.
    private func restoreWindows(
        in group: [TerminalRestorableState],
        appDelegate: AppDelegate
    ) -> Int {
        let ordered = Self.ordered(group)
        let selectedIndex = Self.selectedIndex(in: ordered)
        let isStandalone = ordered.count == 1

        var anchor: TerminalController?
        var anchorState: TerminalRestorableState?
        var selected: TerminalController?
        var previous: TerminalController?
        var restored: [TerminalController] = []
        for (index, state) in ordered.enumerated() {
            let controller = TerminalController.init(
                appDelegate.ghostty,
                withSurfaceTree: state.surfaceTree)
            guard let window = controller.window else { continue }

            if let tabColor = state.tabColor {
                (window as? TerminalWindow)?.tabColor = tabColor
            }
            controller.titleOverride = state.titleOverride

            if let focusedStr = state.focusedSurface {
                var foundView: Ghostty.SurfaceView?
                for view in controller.surfaceTree where view.id.uuidString == focusedStr {
                    foundView = view
                    break
                }
                if let view = foundView {
                    controller.focusedSurface = view
                    Self.restoreFocus(to: view, inWindow: window)
                }
            }

            /// Only the anchor window carries the frame and fullscreen state;
            /// hidden tabs share its geometry. Fullscreen waits until the
            /// window is on screen, which is the only place the transitions
            /// work at all — a window that has never been shown has no
            /// `screen`, and non-native fullscreen gives up without one. A
            /// tab group's frame is the exception: it has to be set before the
            /// tabs join, so the group forms at the size it was left at.
            if anchor == nil {
                anchorState = state
                if !isStandalone, let frame = Self.restoredFrame(for: state) {
                    window.setFrame(frame, display: false)
                }
            }

            if anchor == nil {
                anchor = controller
            } else if window.tabbingMode == .disallowed {
                // Tabbing is disabled for this window: it stands alone.
                window.orderFrontRegardless()
            } else {
                // Join the tab group while the window is still off screen,
                // mirroring how `newWindow` creates tabs.
                //
                // The result is checked rather than discarded: when AppKit
                // refuses the grouping, the window has been created and is
                // holding a live shell but is on no screen and in no tab
                // bar. Showing it loose is a visible degradation; dropping
                // it is a terminal that silently doesn't exist.
                let joined = previous?.window?
                    .addTabbedWindowSafely(window, ordered: .above) ?? false
                if !joined {
                    /// The line that decides whether "N tabs came back as N
                    /// windows" can ever be diagnosed: this branch was silent,
                    /// and a session of loose windows was indistinguishable
                    /// from one that was saved that way.
                    WindowBreadcrumbs.note(
                        "restore: tab refused to join its group, shown loose " +
                        "window=\(window.windowNumber)")
                    window.orderFrontRegardless()
                }
            }

            if index == selectedIndex { selected = controller }
            previous = controller
            restored.append(controller)
        }

        // Each sidebar was built before its window had joined the group: a
        // controller (and its sidebar) exists a moment before the tab is
        // added, so every one of them populated a one-row list. Nothing
        // observes the group *forming*, so the correction used to arrive
        // incidentally, on the first click — which is what made the list
        // visibly rebuild from one row to N in front of the user. Telling
        // them once the group is complete is that missing signal.
        //
        // A turn later, because AppKit's tab group bookkeeping is not
        // consistent until the next runloop cycle.
        DispatchQueue.main.async {
            for controller in restored {
                controller.sidebarTabManager?.scheduleRefresh()
            }
        }

        guard let anchorWindow = anchor?.window, let anchorState else { return restored.count }

        if isStandalone {
            // A standalone window must come back as its own window.
            // `TerminalWindow` flips tabbing to `.automatic` on the next
            // runloop turn (that is what lets tabs re-form), but macOS
            // auto-tabs windows that appear in quick succession — a burst of
            // restored standalone windows would merge into one tab group.
            // Lock tabbing down after that flip, and only then show the
            // window, so AppKit never gets the chance to group it. Frame and
            // fullscreen are applied here too, after the window is on screen.
            DispatchQueue.main.async {
                // Restored, not adopted: the lock lasts exactly as long as
                // the window is appearing. Leaving it on is worse than the
                // merge it prevents — `TerminalController.newTab` refuses to
                // make a tab in a `.disallowed` window, so every terminal
                // opened in a restored window afterwards came back as
                // another loose window, for the rest of the session. The
                // previous value is put back rather than `.automatic`
                // assumed, because a hidden-titlebar window disallows
                // tabbing on purpose and must keep doing so.
                let tabbingBeforeReveal = anchorWindow.tabbingMode
                anchorWindow.tabbingMode = .disallowed
                anchorWindow.orderFrontRegardless()

                if let frame = PhantomSessionStore.restoredFrame(for: anchorState) {
                    anchorWindow.setFrame(frame, display: false)
                }
                if let mode = PhantomSessionStore.restoredFullscreenMode(for: anchorState) {
                    anchor?.toggleFullscreen(mode: mode)
                }

                DispatchQueue.main.async {
                    anchorWindow.tabbingMode = tabbingBeforeReveal
                }
            }
            return restored.count
        }

        /// The tab the reader was on is the one shown, rather than the anchor
        /// followed by a correction, so the window never appears on the wrong
        /// tab first. Ordering a background tab front makes it its group's
        /// selection — measured — which is exactly the request here.
        let front = selected?.window ?? anchorWindow
        front.orderFrontRegardless()

        DispatchQueue.main.async {
            /// Said again a turn later because AppKit's tab group bookkeeping
            /// is not consistent until the next runloop cycle, and a group
            /// that had never been on screen may have shown itself without
            /// moving its selection.
            if let group = front.tabGroup, group.selectedWindow !== front {
                group.selectedWindow = front
            }

            /// Fullscreen last, and only from here: a group has to exist and
            /// be on screen before it can go fullscreen — a window that has
            /// never been shown has no `screen`, which is where non-native
            /// fullscreen gives up — and the state belongs to the window
            /// rather than to any one tab. Leaving it to AppKit, as the group
            /// path used to, could not work: AppKit's own restoration has no
            /// part in a terminal window — see `ownsTerminalRestoration`.
            if let mode = PhantomSessionStore.restoredFullscreenMode(for: anchorState) {
                anchor?.toggleFullscreen(mode: mode)
            }
        }

        return restored.count
    }

    /// Retries making the given surface the first responder until the
    /// restored window's SwiftUI content catches up. Mirrors the focus
    /// restoration in `TerminalWindowRestoration`.
    private static func restoreFocus(
        to view: Ghostty.SurfaceView,
        inWindow: NSWindow,
        attempts: Int = 0
    ) {
        let after: DispatchTime
        if attempts == 0 {
            after = .now()
        } else if attempts > 40 {
            return
        } else {
            after = .now() + .milliseconds(50)
        }

        DispatchQueue.main.asyncAfter(deadline: after) {
            guard let viewWindow = view.window else {
                restoreFocus(to: view, inWindow: inWindow, attempts: attempts + 1)
                return
            }
            guard viewWindow == inWindow else { return }
            inWindow.makeFirstResponder(view)
            if viewWindow.isMainWindow {
                viewWindow.orderFront(nil)
            }
        }
    }
}
