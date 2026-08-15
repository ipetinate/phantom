import AppKit
import Foundation
import OSLog

/// The language servers this window is talking to, and what they said.
///
/// One server per (language, workspace root) rather than per file: a server
/// builds a project-wide index, and starting a second one for the next file
/// in the same project pays for that index twice and answers half the
/// questions — cross-file references need the whole workspace in one
/// process.
@MainActor
final class LSPCenter: ObservableObject {
    static let shared = LSPCenter()

    /// Nothing under `Editor/LSP/` logged anything at all, which made every
    /// question about this subsystem unanswerable after the fact: "there
    /// were no completions" has at least six causes and they are
    /// indistinguishable from the outside. One line per request and one per
    /// reply, at debug level, with the fields that separate those causes —
    /// and the file's own name rather than its path, since a full path is
    /// the user's business and a log is not.
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: LSPCenter.self)
    )

    /// Problems per file path, which is what the editor draws.
    @Published private(set) var diagnostics: [String: [LSPDiagnostic]] = [:]

    /// The same problems, kept apart by the server that reported them.
    ///
    /// The published dictionary above is a *view*, and it cannot also be the
    /// storage. `publishDiagnostics` replaces a server's entire list for a
    /// file, so with two servers on one document a wholesale write means each
    /// erases the other: last to speak wins, and the underlines flicker
    /// between two truths that are both correct. Split here, merged there —
    /// see `republishDiagnostics(for:)`.
    private var diagnosticsByServer: [String: [Key: [LSPDiagnostic]]] = [:]

    /// What each server is doing right now, keyed by (language, workspace
    /// root). See `LSPServerStatus` for why this replaced a plain
    /// "installed or not" flag.
    ///
    /// Fully `private` rather than `private(set)`: `Key` is private to
    /// this type, so a getter any less restricted than that couldn't
    /// expose this property's type at all. Nothing outside this class
    /// reads it directly anyway — `status(forPath:)` below is the surface.
    @Published private var status: [Key: LSPServerStatus] = [:]

    /// One running server: the language it serves, the workspace it serves it
    /// in, **and the command it runs**.
    ///
    /// The command is not decoration. Two servers can serve the same language
    /// in the same workspace, and `.vue` is exactly that case — the document
    /// has to be announced as `vue` to the Vue server *and* to
    /// `typescript-language-server`, because it is the TypeScript plugin's own
    /// `modeIds` that registers the second one for `vue`. Keyed by language
    /// and root alone those two collapse into one entry, and the second server
    /// silently takes the first one's place.
    ///
    /// It also deletes a lookup rather than adding one: every place that held
    /// a key and wanted to know which binary it meant used to ask the registry
    /// again by language id, which cannot answer once there are two.
    private struct Key: Hashable, Sendable {
        let languageID: String
        let root: String

        /// After any user override — this is what `LSPProcess` will launch.
        let command: String
    }

    /// The key one definition runs under for one file.
    ///
    /// The single place a `Key` is built, so the three fields cannot drift
    /// apart between call sites.
    private static func key(for definition: LSPServerDefinition, path: String) -> Key {
        Key(
            languageID: definition.languageID,
            root: workspaceRoot(for: path),
            command: definition.command
        )
    }

    private var servers: [Key: LSPProcess] = [:]
    private var starting: Set<Key> = []

    /// What `initialize` answered with, so a feature can tell "the server
    /// answered empty" apart from "the server never claimed to offer this".
    private var serverCapabilities: [Key: LSPValue] = [:]

    /// The completion half of the above, parsed once at `initialize`.
    ///
    /// Cached as a typed value rather than walked on demand because the
    /// typing path asks "is this character a trigger" on *every* character,
    /// and that is not a question to answer with three dictionary lookups
    /// and an array scan. See `LSPCompletionCapability`.
    private var completionSupport: [Key: LSPCompletionCapability] = [:]

    /// The server's recent stderr, kept after the process exits or fails to
    /// start — that is precisely when it is worth reading. Cleared when a
    /// fresh attempt starts, so a crash from three runs ago doesn't linger
    /// under a server that is now healthy.
    private var serverLogs: [Key: [String]] = [:]

    /// Consecutive timeouts on requests to a running server. Reset on any
    /// answer; past the threshold the server is reported `unresponsive`
    /// rather than each caller silently getting nothing back.
    private var consecutiveTimeouts: [Key: Int] = [:]
    private static let unresponsiveThreshold = 3
    private static let logTailLimit = 200

    /// Version per open document. The protocol requires it to increase on
    /// every change, and a server that sees it go backwards may discard the
    /// edit or desynchronise outright.
    private var versions: [String: Int] = [:]

    private var openDocuments: Set<String> = []

    /// Which servers each open document has been announced to.
    ///
    /// `didOpen` twice for the same document is a protocol violation, and a
    /// server that starts *after* a file was opened has never heard of it —
    /// both are true at once, so "is it open" is not a property of the
    /// document but of the pair.
    ///
    /// A set rather than one key, because a document served by two servers is
    /// announced to them independently: the second may start minutes after the
    /// first, or fail to start at all, and neither outcome may cost the other
    /// its introduction.
    private var announced: [String: Set<Key>] = [:]

    /// Which server binaries are on the login `PATH`, resolved off the main
    /// actor and republished whenever that could have changed.
    ///
    /// Locating a command means reading the login shell's `PATH`, and
    /// resolving that runs `$SHELL -lic` with a five-second timeout the
    /// first time it is asked. The Settings list asked for it from inside
    /// `body`, once per row, on the main actor — twenty blocking shells to
    /// draw one window. Nothing reads this before the first probe answers;
    /// until then the status is `unknown`, which is the honest thing to say
    /// and the one state that doesn't invite the user to install something
    /// they already have.
    @Published private(set) var installedCommands: Set<String> = []

    /// Whether the probe has answered at least once. See `installedCommands`.
    @Published private(set) var hasProbedInstalls = false

    private var isProbingInstalls = false
    private var probeRequestedAgain = false

    /// Bumped whenever a server that was missing becomes available, so the
    /// open documents can introduce themselves to it.
    ///
    /// A counter rather than the text: this object does not keep a copy of
    /// any buffer, and it should not start now — the documents own their
    /// text and can hand it over when asked.
    @Published private(set) var availabilityGeneration = 0

    /// Watches the directories on the login `PATH` for a server appearing.
    private var pathWatcher: DirectoryWatcher?

    /// Pending `didChange` per document.
    ///
    /// Full-document sync is deliberate — see `didChange` — but sending it
    /// on literally every keystroke means shipping the whole file down a
    /// pipe per character. Coalescing a burst of typing into one update
    /// keeps the safety and drops the cost by an order of magnitude.
    private var changeTasks: [String: Task<Void, Never>] = [:]

    /// The text each pending change would send. Held separately so a flush
    /// can *send* the waiting edit rather than cancel it — dropping it
    /// would desynchronise the server's copy permanently, which is the one
    /// failure full-document sync exists to rule out.
    private var pendingChanges = LSPPendingChanges()

    /// The completion request in flight per document.
    ///
    /// Held so that an edit can cancel it *before* the text under it
    /// changes. See `didChange`, where the order is the whole fix.
    private var completionRequests: [String: Task<LSPCompletionOutcome, Never>] = [:]

    /// The `completionItem/resolve` in flight per document.
    ///
    /// At most one, because resolve is driven by the selection moving and
    /// arrow-keying down a list would otherwise leave a request per row in
    /// flight, each one of them about to be superseded.
    private var resolveRequests: [String: Task<LSPResolveOutcome, Never>] = [:]

    /// Which generation of completion answer each document is on.
    ///
    /// Bumped when a request is *sent*, not when it answers, and stamped onto
    /// the items that come back. It exists because a late resolve is not
    /// merely useless, it is indistinguishable from a real empty answer —
    /// see `LSPCompletion.isCurrent(inEpoch:)`.
    private var completionEpochs: [String: Int] = [:]

    private static let changeDebounce = Duration.milliseconds(180)

    private init() {
        watchPathForInstalls()
        refreshInstalledCommands()

        // Installing happens in the terminal and is followed by coming back
        // to the editor. Free to check, and it is the actual gesture.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func applicationBecameActive() {
        recheckMissingServers()
        refreshInstalledCommands()
    }

    /// Re-resolves which server binaries exist, off the main actor, and
    /// publishes the answer for anything that draws from it.
    ///
    /// Coalesced rather than queued: three notifications arriving together —
    /// the `PATH` watcher, app activation, an install finishing — are one
    /// question. A request that arrives *during* a probe is asked again
    /// afterwards instead of being dropped, because the probe in flight
    /// read its `PATH` before whatever just changed it: that is exactly the
    /// install whose new binary would otherwise stay invisible.
    func refreshInstalledCommands() {
        guard !isProbingInstalls else {
            probeRequestedAgain = true
            return
        }
        isProbingInstalls = true

        let commands = Set(
            (LSPServerRegistry.distinctServers + Self.contributedServers())
                .map { Self.effectiveDefinition($0).command }
        )
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> Set<String> in
                let searchPath = LoginEnvironment.executableSearchPath()
                return commands.filter { LSPProcess.locate($0, searchPath: searchPath) != nil }
            }.value

            guard let self else { return }
            self.isProbingInstalls = false
            self.hasProbedInstalls = true
            self.installedCommands = found

            guard self.probeRequestedAgain else { return }
            self.probeRequestedAgain = false
            self.refreshInstalledCommands()
        }
    }

    /// Whether this server's binary is on the login `PATH`, from the last
    /// probe rather than a fresh one. False until the first probe answers —
    /// ask `hasProbedInstalls` to tell that apart from a real absence.
    func isInstalled(_ server: LSPServerDefinition) -> Bool {
        installedCommands.contains(Self.effectiveDefinition(server).command)
    }

    /// Watches the `PATH` directories so an install is noticed as it happens.
    ///
    /// Reactive rather than polled: `npm i -g` and `brew install` both end by
    /// creating an entry in a bin directory, which is a filesystem event. The
    /// watched set is the login `PATH` — about fifteen directories — and the
    /// only thing done with an event is re-probing the commands already known
    /// to be missing. Nothing is scanned.
    private func watchPathForInstalls() {
        Task { [weak self] in
            let directories = await Task.detached(priority: .utility) {
                Set((LoginEnvironment.loginPath() ?? "").split(separator: ":").map(String.init))
            }.value

            await MainActor.run {
                guard let self, !directories.isEmpty else { return }
                let watcher = DirectoryWatcher()
                watcher.onChange = { [weak self] _ in
                    Task { @MainActor in self?.recheckMissingServers() }
                }
                watcher.watch(directories)
                self.pathWatcher = watcher
            }
        }
    }

    /// Looks again for the servers that were not installed.
    ///
    /// The bug this fixes: a command that could not be found used to go
    /// into an append-only list and nothing ever looked again, so the
    /// banner outlived the install and only a restart cleared it — the
    /// signature of a cache with no invalidation.
    /// The Settings install/uninstall flow calls this when a server binary
    /// appears or disappears, so the "Install"/"Uninstall" toggle and any
    /// "not installed" banner re-check from a fresh locate.
    func noteAvailabilityChanged() {
        availabilityGeneration += 1
        refreshInstalledCommands()
    }

    func recheckMissingServers() {
        // Read off the key rather than resolved again by language id, which
        // cannot answer once one language has two servers.
        let notInstalledCommands = Set(status.compactMap { key, value -> String? in
            guard case .notInstalled = value else { return nil }
            return key.command
        })
        guard !notInstalledCommands.isEmpty else { return }

        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> Set<String> in
                var searchPath = LoginEnvironment.executableSearchPath()
                var located = notInstalledCommands.filter {
                    LSPProcess.locate($0, searchPath: searchPath) != nil
                }

                // Nothing found could mean nothing installed — or a `PATH`
                // captured before the version manager moved the directory.
                // One retry on a fresh resolve tells the two apart.
                if located.isEmpty {
                    LoginEnvironment.invalidate()
                    searchPath = LoginEnvironment.executableSearchPath()
                    located = notInstalledCommands.filter {
                        LSPProcess.locate($0, searchPath: searchPath) != nil
                    }
                }
                return located
            }.value

            guard !found.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                for key in Array(self.status.keys) {
                    guard case .notInstalled = self.status[key],
                          found.contains(key.command)
                    else { continue }
                    self.status.removeValue(forKey: key)
                }
                // The open documents have to introduce themselves: a server
                // starting now has never heard of a file opened before it.
                self.availabilityGeneration += 1
            }
        }
    }

    // MARK: What starts for a file

    /// What would start for a file: the compiled-in registry first, then a
    /// user extension, then a bundled one. `LanguageResolver` owns that
    /// order — see its `serverDefinition(forPath:)` — and these two functions
    /// are the only door into it from here, so the precedence is not
    /// re-derived once per call site.
    ///
    /// **If this subsystem is ever taken apart, the order to restore it in is
    /// the gate first.** `LanguageTrustGate.allowsLaunch` in
    /// `server(for:definition:)` has to be in the path before — or in the same
    /// commit as — these functions. Reaching for the resolver while the gate
    /// is missing is what turns a text file into a process: `command`, written
    /// by whoever dropped a directory into `~/.config/phantom/extensions/`,
    /// would travel from here to `Process.run` with nothing asked in between.
    /// The reverse order is inert — a gate with no resolver behind it can only
    /// refuse launches that never arrive — which is why *that* half is the one
    /// that is safe to land alone.
    /// Every server for a file, override applied, primary first.
    ///
    /// The override is applied *here* rather than at each call site, because
    /// the command it changes is part of the `Key` now: a caller that resolved
    /// and forgot to apply it would key its server under a command nothing
    /// else uses, and the entry would look like a second server that never
    /// answers.
    private static func resolvedServers(forPath path: String) -> [LSPServerDefinition] {
        resolvedPairs(forPath: path).map(\.effective)
    }

    /// Every server for a file, each paired with the definition it came from
    /// before any override — and filtered to the ones that may be handed this
    /// file at all.
    ///
    /// The base is kept because an override is stored under the command it
    /// replaces, so reading one back requires knowing what that was.
    /// `Key.command` cannot answer — it is the command *after* the override —
    /// and asking the registry by language id cannot either, now that one
    /// language can have two servers: it would hand the secondary the
    /// primary's override.
    ///
    /// **The filter is here and nowhere else, and it is applied to the
    /// effective command rather than the base.** That ordering is the whole
    /// point: a user override that repoints some language at `tsc` produces a
    /// definition this file never wrote, and checking the base would wave it
    /// through. See `LSPServerRegistry.accepts(command:path:)` for what is
    /// being refused and why a field on the definition could not do it.
    private static func resolvedPairs(
        forPath path: String
    ) -> [(base: LSPServerDefinition, effective: LSPServerDefinition)] {
        LanguageResolver.shared.serverDefinitions(forPath: path)
            .map { (base: $0, effective: effectiveDefinition($0)) }
            .filter { LSPServerRegistry.accepts(command: $0.effective.command, path: path) }
    }

    private static func resolvedServer(forPath path: String) -> LSPServerDefinition? {
        resolvedServers(forPath: path).first
    }

    /// The same resolution keyed by language id, for the paths that start
    /// from a `Key` rather than from a file. See `resolvedServer(forPath:)`
    /// for the rule that governs both.
    private static func resolvedServer(forLanguage languageID: String) -> LSPServerDefinition? {
        LanguageResolver.shared.serverDefinition(forLanguage: languageID)
    }

    /// The servers contributed by manifests that are actually in force.
    ///
    /// Used only where the question is *display* — "would this be found on
    /// `PATH`" — never where it is launch. Locating a manifest-supplied
    /// command is a `stat`, and it is the same `stat` the Settings row needs
    /// to avoid telling a reader that a server they installed is missing.
    ///
    /// Reached from `refreshInstalledCommands`, which runs during this
    /// object's own `init`, so `LanguageResolver` is constructed from inside
    /// `LSPCenter.shared`. That direction is fine and the reverse is not:
    /// see `LanguageResolver.noteResolutionChanged`.
    private static func contributedServers() -> [LSPServerDefinition] {
        LanguageResolver.shared.catalog.contributed.compactMap(\.serverDefinition)
    }

    // MARK: Documents

    /// Introduces a document to every server that serves it.
    ///
    /// The version is *not* reset for a document already open. A second server
    /// joining a document the first has been editing for a while must be told
    /// the version that document is actually on: told `1`, it would then see
    /// the next change arrive as `2` while the first server sees it as `8`,
    /// and only one of those two servers is reading a document whose numbering
    /// means anything.
    func didOpen(path: String, text: String) {
        let pairs = Self.resolvedPairs(forPath: path)
        guard !pairs.isEmpty else { return }

        if !openDocuments.contains(path) { versions[path] = 1 }
        openDocuments.insert(path)
        let version = versions[path] ?? 1

        for (base, definition) in pairs {
            let key = Self.key(for: definition, path: path)

            // Already announced to *this* server: a second `didOpen` for the
            // same pair is a protocol violation. Not announced to it — even
            // when its sibling has been — means this is the introduction.
            guard announced[path]?.contains(key) != true else { continue }

            Task { [weak self] in
                guard let server = await self?.server(
                    for: key,
                    definition: definition,
                    baseCommand: base.command
                ) else { return }
                await MainActor.run { _ = self?.announced[path, default: []].insert(key) }
                try? server.notify("textDocument/didOpen", params: [
                    "textDocument": [
                        "uri": .string(Self.uri(path)),
                        "languageId": .string(definition.languageID),
                        "version": .integer(version),
                        "text": .string(text),
                    ],
                ])
            }
        }
    }

    /// Records an edit, coalesced behind `changeDebounce`.
    ///
    /// Sends the whole document rather than a delta. Incremental sync is
    /// faster on paper and is where desynchronisation bugs come from: one
    /// wrong range and the server's copy diverges from yours permanently,
    /// with every answer after that subtly wrong and no way to notice. Full
    /// sync is a few kilobytes per keystroke on a file this editor will open
    /// at all, and it cannot drift.
    ///
    /// A completion in flight is cancelled *first*, before the new text is
    /// staged, and the order is the entire fix for a bug that reads as "the
    /// completion inserted the wrong thing". Measured:
    /// `typescript-language-server` calls
    /// `cancelInflightRequestsForResource` when it sees a `didChange`, and
    /// the cancelled tsserver request comes back as an **empty
    /// `CompletionList`, not an error** — indistinguishable from "nothing to
    /// suggest", so a list on screen would be cleared as though the answer
    /// were real. Cancelling from this side instead means the caller is told
    /// `.cancelled` and keeps what it is showing.
    func didChange(path: String, text: String) {
        guard !Self.resolvedServers(forPath: path).isEmpty,
              openDocuments.contains(path)
        else { return }

        cancelCompletion(path: path)

        changeTasks[path]?.cancel()
        pendingChanges.stage(text, for: path)
        changeTasks[path] = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushChange(path: path) }
        }
    }

    /// Sends the pending change, and does it before anything that needs the
    /// server's answer to be about the text on screen.
    ///
    /// Peek, then guard, then remove — in that order, because the order is
    /// the bug. The version that removed the text *before* looking for the
    /// server threw away every character typed while a server was still
    /// starting: the `guard` returned and the text was already gone. Full
    /// document sync hid it, since the next keystroke resends the whole
    /// buffer, so the loss was invisible right up until the user stopped
    /// typing — which is exactly when completion, hover and save ask their
    /// questions.
    ///
    /// The document version is not advanced on a path that sends nothing
    /// either. A version burned on a notification that never left is
    /// bookkeeping about a message that does not exist, and it costs the one
    /// property that makes a desync debuggable at all: that the number is
    /// how many changes the server has been told about.
    /// One version bump, one text, every server that has the document.
    ///
    /// The version is shared deliberately: it numbers the *document*, not the
    /// conversation with any one server, and both servers are being told the
    /// same edits in the same order. Numbering them separately would be two
    /// counters that have to be kept equal, which is a counter waiting to
    /// disagree.
    private func flushChange(path: String) {
        let live = keys(forPath: path).compactMap { servers[$0] }
        guard let text = pendingChanges.take(path, ifServerExists: !live.isEmpty)
        else { return }

        changeTasks.removeValue(forKey: path)?.cancel()

        let version = (versions[path] ?? 1) + 1
        versions[path] = version

        for server in live {
            try? server.notify("textDocument/didChange", params: [
                "textDocument": ["uri": .string(Self.uri(path)), "version": .integer(version)],
                "contentChanges": [["text": .string(text)]],
            ])
        }
    }

    /// Sends the pending change for one document *now*, and stops the
    /// debounce from firing again after it.
    ///
    /// Cancelling the task is the part that matters, and the reason this is
    /// not simply `flushChange`. A debounced change that fires between a
    /// request and its reply is the same bug `didChange` guards from the
    /// other side: the server sees the resource change while it is computing
    /// an answer about it, and what comes back is an empty list rather than
    /// an error.
    private func flushNow(path: String) {
        changeTasks.removeValue(forKey: path)?.cancel()
        flushChange(path: path)
    }

    /// Abandons the completion request in flight for a document, if any.
    ///
    /// Abandoning is not the same as it failing: the caller is told
    /// `.cancelled`, which the UI is required to ignore rather than treat as
    /// an empty answer. The resolve goes with it — a resolve is about one
    /// item of the list this request is about to replace.
    private func cancelCompletion(path: String) {
        completionRequests.removeValue(forKey: path)?.cancel()
        cancelResolve(path: path)
    }

    private func cancelResolve(path: String) {
        resolveRequests.removeValue(forKey: path)?.cancel()
    }

    /// Moves the document to a new completion generation and reports it.
    private func bumpCompletionEpoch(for path: String) -> Int {
        let epoch = (completionEpochs[path] ?? 0) + 1
        completionEpochs[path] = epoch
        return epoch
    }

    func didSave(path: String, text: String) {
        let keys = keys(forPath: path)
        guard !keys.isEmpty else { return }

        // Before the save notification, so no server is told a file was
        // saved while still holding the text from before the last edits.
        flushChange(path: path)

        for key in keys {
            try? servers[key]?.notify("textDocument/didSave", params: [
                "textDocument": ["uri": .string(Self.uri(path))],
                "text": .string(text),
            ])
        }
    }

    func didClose(path: String) {
        let keys = keys(forPath: path)
        guard !keys.isEmpty else { return }

        openDocuments.remove(path)
        announced.removeValue(forKey: path)
        changeTasks.removeValue(forKey: path)?.cancel()
        cancelCompletion(path: path)
        pendingChanges.discard(path)
        completionEpochs.removeValue(forKey: path)
        versions.removeValue(forKey: path)
        diagnostics.removeValue(forKey: path)
        diagnosticsByServer.removeValue(forKey: path)

        for key in keys {
            try? servers[key]?.notify("textDocument/didClose", params: [
                "textDocument": ["uri": .string(Self.uri(path))],
            ])
        }
    }

    // MARK: Server status

    /// What the server for this file's language is doing right now. Nil
    /// when no server — registry or override — is known for this language
    /// at all, which is the ordinary case for most files a terminal opens.
    func status(forPath path: String) -> LSPServerStatus? {
        guard let key = key(forPath: path) else { return nil }
        return status[key]
    }

    /// Aggregates installation and runtime state for the Settings screen.
    /// A server can be active in more than one workspace, so the count is
    /// included instead of pretending there is one global process.
    func status(for server: LSPServerDefinition) -> LSPServerStatusSnapshot {
        /// Both sides compared *after* any override. The version this
        /// replaced took the key's language id back to the registry, applied
        /// the override to what came back, and compared it against the
        /// caller's raw command — so a server the user had pointed at a
        /// different binary matched nothing, and its row read "not running"
        /// while it was running. Reading the command off the key removes the
        /// lookup and the mismatch at once.
        let effective = Self.effectiveDefinition(server).command
        let states = status.compactMap { key, value -> LSPServerStatus? in
            key.command == effective ? value : nil
        }

        let active = states.filter { if case .running = $0 { return true }; return false }.count
        if active > 0 {
            return LSPServerStatusSnapshot(state: .running, activeWorkspaceCount: active)
        }
        if states.contains(where: { if case .starting = $0 { return true }; return false }) {
            return LSPServerStatusSnapshot(state: .starting, activeWorkspaceCount: 0)
        }
        if let failure = states.first(where: { $0.isFailure && !isNotInstalled($0) }) {
            return LSPServerStatusSnapshot(
                state: .error(failure.summary), activeWorkspaceCount: 0
            )
        }

        // From the cached probe, never a fresh one: this is called from a
        // SwiftUI `body`, once per row. See `installedCommands`.
        guard hasProbedInstalls else {
            return LSPServerStatusSnapshot(state: .unknown, activeWorkspaceCount: 0)
        }
        return LSPServerStatusSnapshot(
            state: isInstalled(server) ? .installed : .notInstalled,
            activeWorkspaceCount: 0
        )
    }

    private func isNotInstalled(_ value: LSPServerStatus) -> Bool {
        if case .notInstalled = value { return true }
        return false
    }

    /// The definition in force for this file's language plus any override —
    /// the registry's, or an extension's where one owns the file type. What a
    /// banner names and what "Check Again" or a log panel act on.
    func definition(forPath path: String) -> LSPServerDefinition? {
        guard let base = Self.resolvedServer(forPath: path) else { return nil }
        return Self.effectiveDefinition(base)
    }

    /// The server's recent stderr, oldest first. Kept after the process
    /// exits or fails to start — that is precisely when it is worth
    /// reading.
    func log(forPath path: String) -> [String] {
        guard let key = key(forPath: path) else { return [] }
        return serverLogs[key] ?? []
    }

    /// Whether the server running for this file's language advertised a
    /// given LSP capability (`hoverProvider`, `definitionProvider`, …).
    /// False for any server not `running`, including one still starting.
    func hasCapability(_ name: String, forPath path: String) -> Bool {
        guard let key = key(forPath: path), let value = serverCapabilities[key]?[name] else { return false }
        if let bool = value.boolValue { return bool }
        return !value.isNull
    }

    /// The raw value a server advertised under a top-level capability.
    ///
    /// `hasCapability` above answers `Bool`, which cannot reach a nested
    /// field: `completionProvider.triggerCharacters` is an array two levels
    /// down, and the whole subtree was stored at `initialize` and then never
    /// read by anything.
    func capability(_ name: String, forPath path: String) -> LSPValue? {
        guard let key = key(forPath: path) else { return nil }
        return serverCapabilities[key]?[name]
    }

    /// What this file's server said it can do for completion, or nil when no
    /// server is running for it. Parsed at `initialize` — see
    /// `LSPCompletionCapability`.
    func completionSupport(forPath path: String) -> LSPCompletionCapability? {
        guard let key = key(forPath: path) else { return nil }
        return completionSupport[key]
    }

    /// Whether this document has been announced to a server, or is on its
    /// way to one.
    ///
    /// The seam `EditorCenter` asks before telling a server that a file
    /// moved. A document nobody opened must not be introduced by a rename:
    /// that would start a language server for a file that is not on screen.
    func isOpen(path: String) -> Bool {
        openDocuments.contains(path)
    }

    /// The registry's definition for a language, with any user override
    /// applied.
    ///
    /// Command and arguments are replaced outright when overridden — a
    /// user pointing at a different binary presumably wants different
    /// arguments too, or none. `initializationOptionsKind` is untouched;
    /// an override's own `initializationOptionsJSON`, when present, is
    /// applied later, where a resolution failure can also be reported —
    /// see `resolvedInitializationOptions`.
    static func effectiveDefinition(_ definition: LSPServerDefinition) -> LSPServerDefinition {
        guard let override = LSPServerOverrideStore.override(for: definition.command) else { return definition }

        var command = definition.command
        let trimmedCommand = override.command.trimmingCharacters(in: .whitespaces)
        if !trimmedCommand.isEmpty { command = trimmedCommand }

        var arguments = definition.arguments
        let trimmedArguments = override.arguments.trimmingCharacters(in: .whitespaces)
        if !trimmedArguments.isEmpty {
            arguments = trimmedArguments.split(separator: " ").map(String.init)
        }

        /// `origin` is carried, and forgetting it is not a cosmetic loss: it
        /// is where the definition came from, and therefore whether starting
        /// it needs the reader's permission. This function rebuilds the value
        /// from a literal, so a field left out here silently reverts to
        /// `.builtIn` — and a contributed server whose command happens to
        /// have an override entry would then launch with **no prompt at
        /// all**, which is the entire trust gate bypassed by an omission
        /// nobody would see in review.
        ///
        /// The whole reason provenance is a field on the value rather than a
        /// side table is that a field cannot be forgotten at the call site.
        /// It can still be forgotten *here*, which is why this comment
        /// exists and why a test pins it.
        return LSPServerDefinition(
            languageID: definition.languageID,
            displayName: definition.displayName,
            command: command,
            arguments: arguments,
            installHint: definition.installHint,
            initializationOptionsKind: definition.initializationOptionsKind,
            origin: definition.origin
        )
    }

    // MARK: Features

    func hover(path: String, position: LSPPosition) async -> String? {
        guard let result = await request("textDocument/hover", path: path, position: position)
        else { return nil }
        return Self.hoverText(from: result["contents"])
    }

    func definition(path: String, position: LSPPosition) async -> [LSPLocation] {
        guard let result = await request("textDocument/definition", path: path, position: position)
        else { return [] }
        return Self.locations(from: result)
    }

    func references(path: String, position: LSPPosition) async -> [LSPLocation] {
        guard let result = await request(
            "textDocument/references",
            path: path,
            position: position,
            extra: ["context": ["includeDeclaration": .bool(true)]]
        ) else { return [] }
        return Self.locations(from: result)
    }

    /// What the server offers at a position.
    ///
    /// The pending change is flushed synchronously first, so the answer is
    /// about the text on screen *and* so the debounce cannot fire in the
    /// middle of the request — see `flushNow`. The request itself is held in
    /// `completionRequests` so the next edit can abandon it rather than let
    /// the server answer a question about text that has since changed.
    ///
    /// - Parameter context: Always sent. `contextSupport: true` with no
    ///   `context` in the params is a lie neither side can detect: the
    ///   server does not fail, it answers a different question.
    /// - Parameter isExplicit: ⌃Space rather than typing, which buys a
    ///   longer deadline. Somebody who asked out loud is willing to wait;
    ///   somebody who is typing is not.
    func completions(
        path: String,
        position: LSPPosition,
        context: LSPCompletionContext = .invoked,
        isExplicit: Bool = false
    ) async -> LSPCompletionOutcome {
        flushNow(path: path)

        /// Before anything is sent, and it takes the previous request and any
        /// resolve with it: every item of the old answer is superseded by
        /// this one, and a resolve that outlives its list gets answered
        /// *unchanged rather than refused* by the server.
        let epoch = bumpCompletionEpoch(for: path)
        cancelCompletion(path: path)

        let request = Task { [weak self] in
            await self?.performCompletion(
                path: path,
                position: position,
                context: context,
                isExplicit: isExplicit,
                epoch: epoch
            ) ?? .noServer
        }

        completionRequests[path] = request
        let outcome = await request.value
        if completionRequests[path] == request { completionRequests.removeValue(forKey: path) }
        return outcome
    }

    private func performCompletion(
        path: String,
        position: LSPPosition,
        context: LSPCompletionContext,
        isExplicit: Bool,
        epoch: Int
    ) async -> LSPCompletionOutcome {
        let answer = await perform(
            "textDocument/completion",
            path: path,
            position: position,
            extra: Self.completionExtra(for: context),
            timeout: isExplicit ? LSPTimeout.completionExplicit : LSPTimeout.completionWhileTyping
        )

        let outcome: LSPCompletionOutcome
        let summary: String
        switch answer {
        case .success(let value):
            let list = LSPCompletionList(value, epoch: epoch)
            outcome = .list(list)
            summary = "items=\(list.items.count) incomplete=\(list.isIncomplete)"
        case .failure(let failure):
            outcome = failure.completionOutcome
            summary = failure.summary
        }

        let name = Self.name(of: path)
        let trigger = context.kind.rawValue
        Self.logger.debug(
            "completion \(name) trigger=\(trigger, privacy: .public) \(summary, privacy: .public)"
        )
        return outcome
    }

    /// Fills in the fields a server only computes when asked.
    ///
    /// Required rather than an optimisation, and for two of the four target
    /// languages it is the *only* source of the thing being asked for:
    /// measured, `typescript-language-server` sets documentation nowhere but
    /// `asResolvedCompletionItem`, and sourcekit-lsp's own log line for
    /// resolve reads "Retrieving documentation for completion item". Without
    /// this call a documentation pane is permanently empty for both, and
    /// auto-import never happens on TypeScript at all.
    ///
    /// Refused rather than sent in two cases, both of which would otherwise
    /// fail silently: an item from a superseded list (`.stale` — the server
    /// would answer it *unchanged and without an error*), and a server that
    /// answers no resolve (`.unsupported`).
    ///
    /// - Parameter item: The item as it came out of the list, which carries
    ///   both the epoch and the server's own payload. Nothing else needs
    ///   plumbing, and nothing at the call site can be got wrong.
    func resolve(
        _ item: LSPCompletion,
        path: String,
        timeout: TimeInterval = LSPTimeout.completionResolve
    ) async -> LSPResolveOutcome {
        guard item.isCurrent(inEpoch: completionEpochs[path] ?? 0) else { return .stale }

        let request = Task { [weak self] in
            await self?.performResolve(item, path: path, timeout: timeout) ?? .noServer
        }

        cancelResolve(path: path)
        resolveRequests[path] = request
        let outcome = await request.value
        if resolveRequests[path] == request { resolveRequests.removeValue(forKey: path) }
        return outcome
    }

    private func performResolve(
        _ item: LSPCompletion,
        path: String,
        timeout: TimeInterval
    ) async -> LSPResolveOutcome {
        guard let key = key(forPath: path), let server = await runningServer(forPath: path) else {
            return .noServer
        }

        /// Asked *after* waiting for the server rather than before, because
        /// until one is running there is no capability to read — and
        /// answering `.unsupported` for a server that is merely still
        /// starting would tell the caller never to ask again.
        guard completionSupport(forPath: path)?.resolveProvider == true else { return .unsupported }

        let name = Self.name(of: path)
        Self.logger.debug("→ completionItem/resolve \(name)")

        let started = Date()
        do {
            /// The item is echoed back exactly as it arrived — see
            /// `LSPCompletion.raw`.
            let result = try await server.request(
                "completionItem/resolve",
                params: item.raw,
                timeout: timeout
            )
            noteRequestSucceeded(for: key)

            /// Checked again on the way out: the list can be superseded while
            /// the reply is in flight, and merging a reply about a dead list
            /// into a live item is the silent-wrong-answer this whole
            /// mechanism exists to prevent.
            guard item.isCurrent(inEpoch: completionEpochs[path] ?? 0) else {
                Self.logger.debug("← completionItem/resolve stale")
                return .stale
            }

            let resolved = item.merging(resolved: result)
            let elapsed = Self.milliseconds(since: started)
            Self.logger.debug(
                """
                ← completionItem/resolve \
                documentation=\(resolved.documentation != nil, privacy: .public) \
                edits=\(resolved.additionalTextEdits.count, privacy: .public) \
                in \(elapsed, privacy: .public)ms
                """
            )
            return .resolved(resolved)
        } catch {
            noteRequestFailed(error, for: key)
            let failure = Self.failure(from: error)
            let elapsed = Self.milliseconds(since: started)
            Self.logger.debug(
                """
                ← completionItem/resolve \(failure.summary, privacy: .public) \
                in \(elapsed, privacy: .public)ms
                """
            )
            return failure.resolveOutcome
        }
    }

    func formatting(path: String, tabSize: Int, insertSpaces: Bool) async -> [LSPTextEdit] {
        guard let key = key(forPath: path), let server = await runningServer(forPath: path) else { return [] }
        do {
            let result = try await server.request("textDocument/formatting", params: [
                "textDocument": ["uri": .string(Self.uri(path))],
                "options": [
                    "tabSize": .integer(tabSize),
                    "insertSpaces": .bool(insertSpaces),
                ],
            ])
            noteRequestSucceeded(for: key)
            return (result.arrayValue ?? []).compactMap(LSPTextEdit.init)
        } catch {
            noteRequestFailed(error, for: key)
            return []
        }
    }

    /// Edits per file path, since a rename crosses files by definition.
    func rename(path: String, position: LSPPosition, to newName: String) async
        -> [String: [LSPTextEdit]] {
        guard let result = await request(
            "textDocument/rename",
            path: path,
            position: position,
            extra: ["newName": .string(newName)]
        ) else { return [:] }

        return Self.workspaceEdits(from: result)
    }

    // MARK: Plumbing

    /// Why a request produced no value.
    ///
    /// Every caller used to collapse all four into `nil`, which is fine for
    /// hover — there is nothing to show either way — and wrong for
    /// completion, where they have different consequences on screen.
    private enum RequestFailure: Error, Equatable {
        case noServer
        case cancelled
        case timedOut
        case failed(String)

        /// Low-cardinality, for a log line. The reason string is the
        /// server's own and is not summarised further.
        var summary: String {
            switch self {
            case .noServer: return "no server"
            case .cancelled: return "cancelled"
            case .timedOut: return "timed out"
            case .failed(let reason): return "failed: \(reason)"
            }
        }

        /// The same four cases, as the thing a completion caller switches on.
        /// Kept as a mapping rather than by reusing this enum in the public
        /// surface: a UI must not be able to receive a case that only makes
        /// sense to the transport.
        var completionOutcome: LSPCompletionOutcome {
            switch self {
            case .noServer: return .noServer
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            case .failed(let reason): return .failed(reason)
            }
        }

        var resolveOutcome: LSPResolveOutcome {
            switch self {
            case .noServer: return .noServer
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            case .failed(let reason): return .failed(reason)
            }
        }
    }

    /// A positional request, with the failure kept rather than flattened.
    private func perform(
        _ method: String,
        path: String,
        position: LSPPosition,
        extra: [String: LSPValue] = [:],
        timeout: TimeInterval = LSPTimeout.deliberate
    ) async -> Result<LSPValue, RequestFailure> {
        guard let key = key(forPath: path), let server = await runningServer(forPath: path) else {
            return .failure(.noServer)
        }

        let params = Self.requestParams(path: path, position: position, extra: extra)

        let name = Self.name(of: path)
        let version = versions[path] ?? 0
        Self.logger.debug(
            """
            → \(method, privacy: .public) lang=\(key.languageID, privacy: .public) \
            \(name) version=\(version, privacy: .public)
            """
        )

        let started = Date()
        do {
            let result = try await server.request(method, params: params, timeout: timeout)
            noteRequestSucceeded(for: key)
            let elapsed = Self.milliseconds(since: started)
            Self.logger.debug("← \(method, privacy: .public) ok in \(elapsed, privacy: .public)ms")
            return .success(result)
        } catch {
            noteRequestFailed(error, for: key)
            let failure = Self.failure(from: error)
            let elapsed = Self.milliseconds(since: started)
            Self.logger.debug(
                """
                ← \(method, privacy: .public) \(failure.summary, privacy: .public) \
                in \(elapsed, privacy: .public)ms
                """
            )
            return .failure(failure)
        }
    }

    /// The three callers that only ever had two answers.
    private func request(
        _ method: String,
        path: String,
        position: LSPPosition,
        extra: [String: LSPValue] = [:]
    ) async -> LSPValue? {
        guard case .success(let result) = await perform(
            method,
            path: path,
            position: position,
            extra: extra
        ) else { return nil }
        return result
    }

    /// The params every positional request is sent with.
    ///
    /// Built by a function rather than inline so that what goes on the wire
    /// can be encoded and asserted without a server in the picture — see
    /// `contextSupportImpliesAContextIsSent`, which is the reason this and
    /// `completionExtra` are separate at all.
    nonisolated static func requestParams(
        path: String,
        position: LSPPosition,
        extra: [String: LSPValue] = [:]
    ) -> LSPValue {
        var params: [String: LSPValue] = [
            "textDocument": ["uri": .string(uri(path))],
            "position": position.value,
        ]
        params.merge(extra) { _, new in new }
        return .object(params)
    }

    /// The non-positional half of a completion request.
    ///
    /// One function, so the invariant is structural: the capability block
    /// claims `contextSupport`, and there is exactly one place where a
    /// request could fail to carry a `context` — this one.
    nonisolated static func completionExtra(
        for context: LSPCompletionContext
    ) -> [String: LSPValue] {
        ["context": context.value]
    }

    private static func failure(from error: Error) -> RequestFailure {
        if error is CancellationError { return .cancelled }
        guard let processError = error as? LSPProcessError else {
            return .failed(String(describing: error))
        }
        if case .timedOut = processError { return .timedOut }
        return .failed(processError.reason)
    }

    /// The file's own name, never its path: a log line is worth having and a
    /// user's directory layout is not this subsystem's to publish.
    private static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Resets the failure count on any answer, and — since a server that
    /// answers again is no longer the problem `unresponsive` described —
    /// clears that state too.
    private func noteRequestSucceeded(for key: Key) {
        consecutiveTimeouts[key] = 0
        if case .unresponsive = status[key] {
            status[key] = .running
        }
    }

    /// Only a timeout counts here. A crash is reported through the
    /// `.exited` event instead, and cancellation is the caller giving up,
    /// not the server failing anybody.
    private func noteRequestFailed(_ error: Error, for key: Key) {
        guard case LSPProcessError.timedOut = error else { return }
        let count = (consecutiveTimeouts[key] ?? 0) + 1
        consecutiveTimeouts[key] = count
        guard count >= Self.unresponsiveThreshold, case .running = status[key] else { return }
        status[key] = .unresponsive
    }

    private func server(forPath path: String) -> LSPProcess? {
        guard let key = key(forPath: path) else { return nil }
        return servers[key]
    }

    private func keys(forPath path: String) -> [Key] {
        Self.resolvedServers(forPath: path).map { Self.key(for: $0, path: path) }
    }

    /// The primary server's key.
    ///
    /// Status, the log, the capability questions and every `perform`-based
    /// feature — hover, definition, references — still answer for the primary
    /// alone. **That is a deferral, not a decision.** It is safe to defer
    /// because in the case that motivates a second server those three come
    /// back empty today anyway: the Vue server serves template and style, and
    /// says nothing about a `<script>` block. So consulting only the primary
    /// keeps exactly what works and loses nothing that does — which is what
    /// makes the second server additive. The rule when it lands is "first
    /// non-empty answer, primary first"; until then this is why there is only
    /// one.
    private func key(forPath path: String) -> Key? {
        keys(forPath: path).first
    }

    /// The server for a file, waiting for it if it is still starting.
    ///
    /// The version that gave up when `servers` was empty made the first
    /// click after opening a file do nothing at all — the server was on its
    /// way, and the request arrived before it. Waiting is what makes the
    /// feature work the first time somebody tries it rather than the
    /// second.
    ///
    /// One exit point, deliberately. The version that returned from inside
    /// the fast path flushed the pending change there and nowhere else, so a
    /// request that had to *wait* for a starting server was answered against
    /// the `didOpen` text — and together with the discard in `flushChange`,
    /// the characters typed while it was starting were gone rather than
    /// merely late. Every path that hands back a server flushes first.
    private func runningServer(forPath path: String) async -> LSPProcess? {
        guard let key = key(forPath: path) else { return nil }

        if servers[key] == nil {
            /// Bounded: a server that never comes up must not leave a click
            /// hanging forever. Cancellation breaks out too — `try?` on the
            /// sleep swallows it, which would otherwise spin the remaining
            /// iterations without sleeping.
            for _ in 0..<60 {
                guard starting.contains(key), !Task.isCancelled else { break }
                try? await Task.sleep(for: .milliseconds(250))
                if servers[key] != nil { break }
            }
        }

        guard let server = servers[key] else { return nil }

        /// Anything typed in the last moment is still queued behind the
        /// debounce, and an answer about stale text is worse than a slow one
        /// — it points at the wrong characters.
        flushPending(for: key)
        return server
    }

    /// Sends any debounced change for the documents this server owns.
    private func flushPending(for key: Key) {
        for path in pendingChanges.paths where keys(forPath: path).contains(key) {
            flushChange(path: path)
        }
    }

    /// Starts a server, or hands back the running one.
    ///
    /// The one function in the app that brings an `LSPProcess` into
    /// existence, which is why the trust gate is here and not at any of the
    /// dozen places that ask for a server. `didOpen`, hover, completion,
    /// rename and the availability sweep all arrive through this door; a
    /// check at each of them would be a check somebody adds a thirteenth
    /// caller without.
    private func server(
        for key: Key,
        definition: LSPServerDefinition,
        baseCommand: String
    ) async -> LSPProcess? {
        if let existing = servers[key] { return existing }
        guard !starting.contains(key) else { return nil }
        starting.insert(key)
        defer { starting.remove(key) }

        // Off the main actor: resolving this runs the login shell the first
        // time it is asked, and this function is main-actor-isolated — the
        // window would be frozen for the whole of it, on the first code
        // file opened in a session.
        let searchPath = await Task.detached(priority: .userInitiated) {
            LoginEnvironment.executableSearchPath()
        }.value
        guard let resolvedPath = LSPProcess.locate(definition.command, searchPath: searchPath) else {
            status[key] = .notInstalled
            return nil
        }

        /// The gate. It sits *after* `locate` because what gets recorded is
        /// an answer about a path: "not installed" is not a trust question,
        /// and until the name has resolved there is nothing to show the user
        /// and nothing an approval could be pinned to. It sits *before* the
        /// status becomes `.starting`, so the window is not claiming to start
        /// something while a sheet is still asking whether it may.
        ///
        /// A compiled-in definition returns `true` without a lookup and
        /// without a prompt — see `LSPServerOrigin`. The key stays in
        /// `starting` for the whole await, which is deliberate: a hover that
        /// arrives while the prompt is up waits for the answer rather than
        /// being told there is no server.
        guard await LanguageTrustGate.allowsLaunch(
            of: definition,
            resolvedPath: resolvedPath,
            workspaceRoot: key.root
        ) else {
            status[key] = .notApproved
            return nil
        }

        // A fresh attempt gets a fresh log and a fresh failure count — a
        // crash from three runs ago must not linger under a server that
        // has since been fixed.
        serverLogs[key] = []
        consecutiveTimeouts[key] = 0
        status[key] = .starting

        let initializationOptions: LSPValue?
        switch await resolvedInitializationOptions(
            for: definition,
            key: key,
            baseCommand: baseCommand,
            searchPath: searchPath
        ) {
        case .failure(let reason):
            status[key] = .failedToStart(reason: reason)
            return nil
        case .success(let value):
            initializationOptions = value
        }

        let process = LSPProcess(definition: definition)
        do {
            try await process.start(workingDirectory: key.root)
            let result = try await process.initialize(
                rootURI: Self.uri(key.root),
                capabilities: Self.clientCapabilities,
                initializationOptions: initializationOptions
            )
            serverCapabilities[key] = result["capabilities"]
            completionSupport[key] = LSPCompletionCapability(result["capabilities"])
        } catch {
            serverLogs[key] = process.recentLog
            status[key] = .failedToStart(reason: (error as? LSPProcessError)?.reason ?? String(describing: error))
            process.terminate()
            return nil
        }

        status[key] = .running
        servers[key] = process
        listen(to: process, key: key)
        return process
    }

    /// `initializationOptions` to send: a user override's raw JSON when
    /// there is one, else the language's own resolution — Vue's `tsdk`
    /// lookup today, nothing for everyone else.
    ///
    /// The override lookup uses the *default* command for this language
    /// rather than `definition.command` — `definition` here may already be
    /// the overridden one, and the override's own identity has to stay
    /// independent of what it changes the command to. Resolved rather than
    /// looked up in the registry so a contributed language, which the
    /// registry has never heard of, keys its override on the command its
    /// manifest asked for instead of falling through to the overridden one.
    ///
    /// `baseCommand` is carried down from `didOpen` rather than resolved
    /// here, and that is the fix for the hazard the single-server version
    /// left behind: asking the registry for "the" server of a language id
    /// answers with the primary, so the `.vue` file's TypeScript half would
    /// have read the *Vue server's* override. `Key.command` cannot stand in
    /// either — it is the command after the override, and the store is keyed
    /// by the one before.
    ///
    /// A manifest's own `initializationOptions` are deliberately **not**
    /// consulted here, even though `LanguageResolver` can supply them. The
    /// approval prompt names a command and a resolved path; it does not show
    /// the options, and for more than one real server an option is enough to
    /// redirect which code the server loads. Wiring them in is a change to
    /// what an approval *means*, so it belongs with a prompt that shows them
    /// and a `LanguageTrustStore.currentRecordVersion` bump, not here.
    private func resolvedInitializationOptions(
        for definition: LSPServerDefinition,
        key: Key,
        baseCommand: String,
        searchPath: String
    ) async -> LSPOutcome<LSPValue?> {
        if let override = LSPServerOverrideStore.override(for: baseCommand) {
            let raw = override.initializationOptionsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                switch Self.parseInitializationOptions(raw) {
                case .success(let value): return .success(value)
                case .failure(let reason): return .failure(reason)
                }
            }
        }

        switch definition.initializationOptionsKind {
        case .none:
            return .success(nil)
        case .vueTypeScriptSDK:
            let root = key.root
            let resolved = await Task.detached(priority: .utility) {
                LSPInitializationOptions.vueTypeScriptSDK(root: root, searchPath: searchPath)
            }.value
            switch resolved {
            case .success(let tsdk): return .success(LSPInitializationOptions.vueValue(tsdk: tsdk))
            case .failure(let reason): return .failure(reason)
            }

        case .vueTypeScriptPlugin:
            /// A failure here is reported rather than swallowed, and that is
            /// the whole point of the case: without the plugin this server
            /// refuses the document, so starting it anyway would spend a
            /// process to produce silence. `failedToStart(reason:)` puts the
            /// sentence in the banner, where the reader can act on it.
            let root = key.root
            let resolved = await Task.detached(priority: .utility) {
                LSPInitializationOptions.vueTypeScriptPlugin(root: root)
            }.value
            switch resolved {
            case .success(let value): return .success(value)
            case .failure(let reason): return .failure(reason)
            }
        }
    }

    private static func parseInitializationOptions(_ json: String) -> LSPOutcome<LSPValue> {
        guard let data = json.data(using: .utf8) else {
            return .failure("initializationOptions isn't valid text.")
        }
        do {
            return .success(try JSONDecoder().decode(LSPValue.self, from: data))
        } catch {
            return .failure("initializationOptions isn't valid JSON: \(error.localizedDescription)")
        }
    }

    /// Diagnostics arrive unprompted, so the only way to receive them is to
    /// keep reading the server's notifications for as long as it lives —
    /// and, now, its log lines and its exit.
    private func listen(to process: LSPProcess, key: Key) {
        Task { [weak self] in
            for await event in process.events {
                switch event {
                case .notification(let notification):
                    await MainActor.run { self?.handle(notification, for: key) }
                case .log(let line):
                    await MainActor.run { self?.appendLog(line, for: key) }
                case .exited(let exitStatus):
                    await MainActor.run { self?.handleExit(exitStatus: exitStatus, key: key) }
                }
            }
        }
    }

    private func handle(_ notification: LSPNotification, for key: Key) {
        switch notification.method {
        case "textDocument/publishDiagnostics":
            guard let uri = notification.params?["uri"]?.stringValue else { return }
            let reported = (notification.params?["diagnostics"]?.arrayValue ?? [])
                .compactMap(LSPDiagnostic.init)
            let path = URL(string: uri)?.path ?? uri
            diagnosticsByServer[path, default: [:]][key] = reported
            republishDiagnostics(for: path)

        /// Where a server says the thing that answers "why are there no
        /// completions": `typescript-language-server` reports "tsserver
        /// crashed and restarted" here, and `kotlin-language-server` reports
        /// that it could not resolve the Gradle classpath. Both were dropped
        /// on the floor — the guard this replaced accepted
        /// `publishDiagnostics` and returned for everything else — so the log
        /// sheet showed stderr only, and a server that reports its failures
        /// through the protocol rather than stderr looked perfectly healthy
        /// while answering nothing.
        case "window/logMessage", "window/showMessage":
            for line in Self.logLines(from: notification) {
                appendLog(line, for: key)
            }

        default:
            return
        }
    }

    /// Rebuilds the one list the editor draws out of what each server said.
    ///
    /// Ordered by `keys(forPath:)`, primary first, so the order a reader sees
    /// is a property of the file rather than of which server happened to
    /// answer first. Keys no longer in that list are still drained — a server
    /// that has stopped serving this file may have diagnostics recorded under
    /// it, and dropping them silently is an error that never goes away —
    /// and they are sorted, because iterating a dictionary is not an order.
    ///
    /// The ordering lives here because it needs the keys; the merging itself
    /// is `merged(_:)`, which needs nothing and is therefore tested.
    private func republishDiagnostics(for path: String) {
        guard let byServer = diagnosticsByServer[path] else {
            diagnostics.removeValue(forKey: path)
            return
        }

        let ordered = keys(forPath: path)
        let orphaned = byServer.keys
            .filter { !ordered.contains($0) }
            .sorted { ($0.languageID, $0.root, $0.command) < ($1.languageID, $1.root, $1.command) }

        diagnostics[path] = Self.merged((ordered + orphaned).map { byServer[$0] ?? [] })
    }

    /// One list out of several, in the order given.
    ///
    /// Deduped on `LSPDiagnostic.id`, which is line, character and message.
    /// Two servers reading the same `<script>` block genuinely do report the
    /// same error, and underlining it twice is how a tooltip ends up saying
    /// everything in duplicate.
    ///
    /// **Concatenation, never a merge that mixes one server's parts with
    /// another's.** Each server maps positions inside a single-file component
    /// through its own copy of the language tooling, and those copies can
    /// disagree about where a `<script>` block starts; taking a range from one
    /// side to use with text from the other would land an edit in the wrong
    /// place. Whole items, in order, first occurrence wins — that is the whole
    /// rule, and it is the one somebody will be tempted to make cleverer.
    nonisolated static func merged(_ lists: [[LSPDiagnostic]]) -> [LSPDiagnostic] {
        var seen: Set<String> = []
        var merged: [LSPDiagnostic] = []
        for list in lists {
            for diagnostic in list where seen.insert(diagnostic.id).inserted {
                merged.append(diagnostic)
            }
        }
        return merged
    }

    /// `window/logMessage` and `window/showMessage` as lines for the log
    /// sheet.
    ///
    /// Tagged by `MessageType`, so a crash notice does not read like a debug
    /// line. Split per line because one entry per notification would let a
    /// server's stack trace count as a single item against the ring's limit
    /// and push out two hundred real ones.
    nonisolated static func logLines(from notification: LSPNotification) -> [String] {
        guard let message = notification.params?["message"]?.stringValue else { return [] }
        let tag = messageTypeTag(notification.params?["type"]?.intValue)
        return message.split(whereSeparator: \.isNewline).map { "[\(tag)] \($0)" }
    }

    /// An absent or unrecognised type is reported as a log line rather than
    /// guessed upwards: inventing a severity a server did not claim is how a
    /// log sheet ends up full of red that means nothing.
    nonisolated private static func messageTypeTag(_ type: Int?) -> String {
        switch type {
        case 1: return "error"
        case 2: return "warning"
        case 3: return "info"
        case 5: return "debug"
        default: return "log"
        }
    }

    private func appendLog(_ line: String, for key: Key) {
        serverLogs[key, default: []].append(line)
        if let count = serverLogs[key]?.count, count > Self.logTailLimit {
            serverLogs[key]?.removeFirst(count - Self.logTailLimit)
        }
    }

    /// The process exited after having run — as opposed to `server(for:)`'s
    /// own `catch`, which is a server that never got this far at all.
    private func handleExit(exitStatus: Int32?, key: Key) {
        servers.removeValue(forKey: key)
        serverCapabilities.removeValue(forKey: key)
        completionSupport.removeValue(forKey: key)
        status[key] = .crashed(status: exitStatus)

        /// A dead server's problems are not the file's problems any more.
        /// This mattered little while one server owned a file — the
        /// underlines were stale but at least consistent — and matters a lot
        /// now: with two servers, one dying leaves its errors sitting beside
        /// the other's live ones, indistinguishable, and nothing ever removes
        /// them.
        for path in diagnosticsByServer.keys {
            guard diagnosticsByServer[path]?.removeValue(forKey: key) != nil else { continue }
            republishDiagnostics(for: path)
        }
    }

    /// The enclosing repository, else the file's own folder.
    ///
    /// A server indexes what it is given, so pointing it at the repository
    /// is what makes cross-file answers possible at all — rooted at one
    /// file's directory, references would only ever find that directory.
    nonisolated static func workspaceRoot(for path: String) -> String {
        var directory = (path as NSString).deletingLastPathComponent
        while directory != "/", !directory.isEmpty {
            if FileManager.default.fileExists(atPath: directory + "/.git") { return directory }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return (path as NSString).deletingLastPathComponent
    }

    nonisolated static func uri(_ path: String) -> String {
        URL(fileURLWithPath: path).absoluteString
    }

    /// Hover comes back as a string, a `{ value: }`, or an array of either.
    nonisolated static func hoverText(from contents: LSPValue?) -> String? {
        guard let contents else { return nil }
        if let text = contents.stringValue { return text.isEmpty ? nil : text }
        if let value = contents["value"]?.stringValue { return value.isEmpty ? nil : value }
        if let array = contents.arrayValue {
            let joined = array.compactMap { hoverText(from: $0) }.joined(separator: "\n\n")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// Definition answers with one location or a list of them.
    nonisolated static func locations(from value: LSPValue) -> [LSPLocation] {
        if let array = value.arrayValue { return array.compactMap(LSPLocation.init) }
        return [LSPLocation(value)].compactMap { $0 }
    }

    /// A `WorkspaceEdit` carries its edits under `changes` keyed by uri, or
    /// under `documentChanges` as a list — servers pick one, and a client
    /// that reads only `changes` gets nothing from the others.
    nonisolated static func workspaceEdits(from value: LSPValue) -> [String: [LSPTextEdit]] {
        var result: [String: [LSPTextEdit]] = [:]

        if case .object(let changes)? = value["changes"] {
            for (uri, edits) in changes {
                let path = URL(string: uri)?.path ?? uri
                result[path] = (edits.arrayValue ?? []).compactMap(LSPTextEdit.init)
            }
        }

        for change in value["documentChanges"]?.arrayValue ?? [] {
            guard let uri = change["textDocument"]?["uri"]?.stringValue else { continue }
            let path = URL(string: uri)?.path ?? uri
            let edits = (change["edits"]?.arrayValue ?? []).compactMap(LSPTextEdit.init)
            result[path, default: []].append(contentsOf: edits)
        }

        return result
    }
}

/// One completion the server offered.
///
/// Deliberately close to the wire. This is the value both the popup and the
/// accept path are built out of, and a field dropped here is a field that
/// has to be guessed later: the version this replaces kept `label`,
/// `detail`, `kind` and a flattened `insertText`, which is enough to draw a
/// list and not enough to insert from one correctly.
struct LSPCompletion: Identifiable, Equatable {
    /// What accepting the item does to the buffer.
    ///
    /// An enum rather than a `newText` plus an optional range, because the
    /// range is the field a caller forgets and forgetting it is not
    /// cosmetic: **a server's range routinely starts before the caret.**
    /// Measured — `typescript-language-server` builds dot-accessor items
    /// whose range covers the `.` and whose `newText` includes it again, so
    /// inserting the text at the caret writes `foo..bar`; and sourcekit-lsp
    /// exposes `completion_item_get_num_bytes_to_erase`, which is the same
    /// instruction in another shape. The editor's own idea of the partial
    /// word is never a substitute for the range the server asked for.
    enum Edit: Equatable {
        /// No range came with the item, so the caller decides what the typed
        /// prefix was.
        case insertAtCaret(String)

        case replace(range: LSPRange, newText: String)

        /// `InsertReplaceEdit`: one text, with a shorter range for
        /// "insert" and a longer one for "replace what follows too".
        /// Understood on the way in even though `insertReplaceSupport` is
        /// deliberately not advertised — a server that sends one anyway
        /// costs nothing to honour.
        case insertReplace(insert: LSPRange, replace: LSPRange, newText: String)

        /// The characters that end up in the buffer, whichever shape this
        /// is. Not a substitute for reading the range — see the note above.
        var newText: String {
            switch self {
            case .insertAtCaret(let text): return text
            case .replace(_, let text): return text
            case .insertReplace(_, _, let text): return text
            }
        }
    }

    /// `label` split into the parts a list draws in separate columns:
    /// `detail` is the signature fragment that follows the name, and
    /// `description` is where the symbol comes from — the module, for an
    /// auto-import. Advertising `labelDetailsSupport` is what makes
    /// `typescript-language-server` fill the second one in at all, which is
    /// the "origin" column this list exists to show.
    struct LabelDetails: Equatable {
        let detail: String?
        let description: String?

        init?(_ value: LSPValue?) {
            guard let value else { return nil }
            let detail = value["detail"]?.stringValue
            let description = value["description"]?.stringValue
            guard detail != nil || description != nil else { return nil }
            self.detail = detail
            self.description = description
        }
    }

    /// Fields a server may send once for a whole list instead of on every
    /// item.
    ///
    /// Parsed and applied even though `completionList.itemDefaults` is
    /// deliberately *not* advertised: advertising it is what makes
    /// sourcekit-lsp — which knows `ItemDefaultsEditRange` — stop sending a
    /// per-item edit at all, and honouring one that arrives unbidden is
    /// free.
    struct ItemDefaults: Equatable {
        /// The list-wide range. `insertReplace` here is the same pair of
        /// ranges an `InsertReplaceEdit` carries per item.
        enum EditRange: Equatable {
            case plain(LSPRange)
            case insertReplace(insert: LSPRange, replace: LSPRange)
        }

        let editRange: EditRange?
        let commitCharacters: [String]?
        let insertTextFormat: Int?
        let data: LSPValue?

        init?(_ value: LSPValue?) {
            guard let value else { return nil }

            if let insert = LSPRange(value["editRange"]?["insert"]),
               let replace = LSPRange(value["editRange"]?["replace"]) {
                self.editRange = .insertReplace(insert: insert, replace: replace)
            } else if let range = LSPRange(value["editRange"]) {
                self.editRange = .plain(range)
            } else {
                self.editRange = nil
            }

            self.commitCharacters = value["commitCharacters"]?.arrayValue?.compactMap(\.stringValue)
            self.insertTextFormat = value["insertTextFormat"]?.intValue
            self.data = value["data"]

            guard editRange != nil || commitCharacters != nil
                || insertTextFormat != nil || data != nil
            else { return nil }
        }
    }

    /// The item exactly as the server sent it.
    ///
    /// Kept so `completionItem/resolve` can hand the server back the *same*
    /// object rather than a reconstruction of it. The specification says the
    /// client sends the item back, and a rebuild from parsed fields silently
    /// drops anything this type does not model — which matters because a
    /// server that cannot recognise the item it is given answers with that
    /// item **unchanged rather than with an error**. Cheap, too: this is the
    /// tree that was already decoded, retained rather than copied.
    let raw: LSPValue

    let label: String
    let labelDetails: LabelDetails?

    /// The four fields below are `var` for exactly one reason: they are the
    /// ones a `completionItem/resolve` reply is allowed to fill in. See
    /// `merging(resolved:)` — everything else stays `let` so that a resolve
    /// cannot quietly take the ordering, the identity or the edit with it.
    var detail: String?
    var documentation: LSPMarkupContent?
    var additionalTextEdits: [LSPTextEdit]
    var command: LSPValue?

    let kind: Int?
    let edit: Edit

    /// The server's ranking. See `precedes` for why it is compared the way
    /// it is, which is the part that is easy to get wrong.
    let sortText: String?

    /// What the typed prefix is matched against — and never what is
    /// inserted. See `matchText`.
    let filterText: String?

    let preselect: Bool
    let isDeprecated: Bool

    /// 1 PlainText, 2 Snippet. Absent means plain text, and that reading is
    /// load-bearing: a `$` in a plain item is a dollar sign, and treating it
    /// as a placeholder mutilates the insertion.
    let insertTextFormat: Int?

    let commitCharacters: [String]

    /// The server's own opaque payload, kept **verbatim**.
    ///
    /// It is the item's identity as far as the server is concerned, and
    /// `completionItem/resolve` has to be handed back the value it was
    /// given. Re-encoding it through any type of ours would hand back a
    /// different value, and a server answering a resolve it cannot match
    /// returns the item *unchanged rather than failing* — an auto-import
    /// that silently does not happen.
    let data: LSPValue?

    /// Where the server put this item in its own list. The tie-break that
    /// makes ordering total, and half of `id`.
    let index: Int

    /// Which generation of completion answer this item came from.
    ///
    /// Not protocol data — bookkeeping, and the only defence against a
    /// resolve that answers about a list nobody is looking at any more. See
    /// `isCurrent(inEpoch:)`.
    let epoch: Int

    /// Stable within one list, which is all identity has to be here: a popup
    /// keeps its selection across a re-filter of the same answer and
    /// discards it on a new one. `label + detail` was not even that —
    /// overloads collide, and both `typescript-language-server` and
    /// `kotlin-language-server` emit them.
    var id: String { "\(index):\(label)" }

    /// The text to match what the user has typed against.
    ///
    /// **Match on this; never insert it.** Measured: in
    /// `typescript-language-server` an optional member arrives as
    /// `label: "foo?"` with `filterText: "foo"`, and a dot-accessor item
    /// arrives with `filterText: ".foo"`. Inserting either one leaves a
    /// stray `.` in the buffer or loses the `?`.
    var matchText: String { filterText ?? label }

    /// What ends up in the buffer. Derived from `edit`, so `filterText`
    /// cannot reach it by construction.
    var insertText: String { edit.newText }

    var isSnippet: Bool { insertTextFormat == 2 }

    /// What ordering compares against. `sortText` is a ranking key, not a
    /// display string.
    var sortKey: String { sortText ?? label }

    /// Whether this item still describes the list the document is showing.
    ///
    /// The rule `completionItem/resolve` is gated on. Measured:
    /// `typescript-language-server` calls `completionDataCache.reset()` at the
    /// start of **every** `textDocument/completion`, so a resolve carrying an
    /// id from a superseded list comes back **unchanged and without an
    /// error** — the documentation is silently empty and the auto-import
    /// silently absent, and neither is distinguishable from a server that had
    /// nothing to add. Refusing to send is the only way to tell the two
    /// apart.
    func isCurrent(inEpoch epoch: Int) -> Bool { self.epoch == epoch }

    init?(_ value: LSPValue, index: Int = 0, defaults: ItemDefaults? = nil, epoch: Int = 0) {
        guard let label = value["label"]?.stringValue else { return nil }

        self.raw = value
        self.label = label
        self.index = index
        self.epoch = epoch
        self.labelDetails = LabelDetails(value["labelDetails"])
        self.detail = value["detail"]?.stringValue
        self.documentation = LSPMarkupContent(value["documentation"])
        self.additionalTextEdits = (value["additionalTextEdits"]?.arrayValue ?? [])
            .compactMap(LSPTextEdit.init)
        self.kind = value["kind"]?.intValue
        self.sortText = value["sortText"]?.stringValue
        self.filterText = value["filterText"]?.stringValue
        self.preselect = value["preselect"]?.boolValue ?? false
        self.isDeprecated = Self.deprecated(from: value)
        self.insertTextFormat = value["insertTextFormat"]?.intValue ?? defaults?.insertTextFormat
        self.command = value["command"]
        self.data = value["data"] ?? defaults?.data
        self.edit = Self.resolvedEdit(from: value, label: label, defaults: defaults)

        if let own = value["commitCharacters"]?.arrayValue {
            self.commitCharacters = own.compactMap(\.stringValue)
        } else {
            self.commitCharacters = defaults?.commitCharacters ?? []
        }
    }

    /// The edit, in the priority the specification gives it: the item's own
    /// `textEdit`, then the list's default range paired with the item's
    /// `textEditText`, then a bare insertion at the caret.
    ///
    /// `textEditText` is the field that exists *for* `itemDefaults.editRange`
    /// — a server sending list-wide ranges puts the text there rather than in
    /// `insertText` — so reading only `insertText` would find nothing on
    /// exactly the servers that use defaults.
    private static func resolvedEdit(
        from value: LSPValue,
        label: String,
        defaults: ItemDefaults?
    ) -> Edit {
        let text = value["textEdit"]?["newText"]?.stringValue
            ?? value["textEditText"]?.stringValue
            ?? value["insertText"]?.stringValue
            ?? label

        if let textEdit = value["textEdit"] {
            if let insert = LSPRange(textEdit["insert"]), let replace = LSPRange(textEdit["replace"]) {
                return .insertReplace(insert: insert, replace: replace, newText: text)
            }
            if let range = LSPRange(textEdit["range"]) {
                return .replace(range: range, newText: text)
            }
        }

        switch defaults?.editRange {
        case .plain(let range):
            return .replace(range: range, newText: text)
        case .insertReplace(let insert, let replace):
            return .insertReplace(insert: insert, replace: replace, newText: text)
        case nil:
            return .insertAtCaret(text)
        }
    }

    /// Applies a `completionItem/resolve` reply to the item that was sent.
    ///
    /// Field by field, and only the four the reply is allowed to fill in —
    /// which is why those four, and only those, are `var`. Replacing the
    /// whole item with the reply loses `sortText`, and servers do drop it on
    /// resolve: the list is already drawn in that order, so a naive
    /// replacement re-ranks the list under the selection that triggered the
    /// resolve.
    ///
    /// A field the reply omits keeps the value the item already had. `null`
    /// counts as omitted rather than as an instruction to clear, since a
    /// server has no reason to send one and reading it as "delete the
    /// documentation you already have" would be the worse guess.
    ///
    /// `raw` deliberately stays the item the *server* sent, not the reply, so
    /// a second resolve echoes back what the server first recognised rather
    /// than its own answer.
    func merging(resolved: LSPValue) -> LSPCompletion {
        var merged = self

        if let detail = resolved["detail"]?.stringValue, !detail.isEmpty {
            merged.detail = detail
        }
        if let documentation = LSPMarkupContent(resolved["documentation"]) {
            merged.documentation = documentation
        }
        if let edits = resolved["additionalTextEdits"]?.arrayValue {
            merged.additionalTextEdits = edits.compactMap(LSPTextEdit.init)
        }
        if let command = resolved["command"], !command.isNull {
            merged.command = command
        }

        return merged
    }

    /// Both spellings. `tags: [1]` is the current one; `deprecated: true` is
    /// the pre-3.15 flag servers still send. Reading one of them draws half
    /// the deprecated symbols as ordinary ones.
    private static func deprecated(from value: LSPValue) -> Bool {
        if value["deprecated"]?.boolValue == true { return true }
        return (value["tags"]?.arrayValue ?? []).contains { $0.intValue == 1 }
    }

    /// The server's own ranking, applied.
    static func ordered(_ items: [LSPCompletion]) -> [LSPCompletion] {
        items.sorted { precedes($0, $1) }
    }

    /// A total order over one list: `sortText` first, then `label`, then the
    /// position the server sent the item in.
    ///
    /// The index tie-break is not decoration — `sorted(by:)` is not
    /// guaranteed stable in Swift, so without it two items with the same
    /// keys could swap between two calls on the same data.
    static func precedes(_ lhs: LSPCompletion, _ rhs: LSPCompletion) -> Bool {
        if lhs.sortKey != rhs.sortKey { return precedes(lhs.sortKey, rhs.sortKey) }
        if lhs.label != rhs.label { return precedes(lhs.label, rhs.label) }
        return lhs.index < rhs.index
    }

    /// **Plain scalar-wise lexicographic comparison** — never
    /// `localizedStandardCompare`, never case-insensitive, and spelled out
    /// rather than left to `String`'s own `<`, which compares canonically
    /// equivalent forms and is not defined as scalar order.
    ///
    /// Both reasons are measured. `typescript-language-server` prefixes
    /// auto-import items with `U+FFFF` for the express purpose of sinking
    /// them below everything local, and `kotlin-language-server` sets
    /// `sortText` to the item's index zero-padded to two digits ("00"…"74"),
    /// which is pure positional ranking. A locale-aware collation treats
    /// `U+FFFF` as ignorable and reorders digit strings by its own rules:
    /// either way both servers' rankings are destroyed, and the item the
    /// server put first is no longer first.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars) { $0.value < $1.value }
    }
}

/// A whole answer to `textDocument/completion`.
struct LSPCompletionList: Equatable {
    /// In the order the server sent them, since that order is what `index`
    /// means. Ranking is `ordered`, deliberately a separate step: a filter
    /// runs first, and the score it produces for what the user actually
    /// typed outranks `sortText`.
    let items: [LSPCompletion]

    /// The server saying "this list is a guess for this prefix; ask again
    /// when it changes". Discarded entirely before — the parse read `items`
    /// and nothing else — which turns every re-request into a local
    /// re-filter of a list the server already said was wrong.
    let isIncomplete: Bool

    let itemDefaults: LSPCompletion.ItemDefaults?

    var isEmpty: Bool { items.isEmpty }

    var ordered: [LSPCompletion] { LSPCompletion.ordered(items) }

    init(
        items: [LSPCompletion],
        isIncomplete: Bool = false,
        itemDefaults: LSPCompletion.ItemDefaults? = nil
    ) {
        self.items = items
        self.isIncomplete = isIncomplete
        self.itemDefaults = itemDefaults
    }

    /// A server answers with a bare array or with `{ items: [...] }`;
    /// handling only one of them silently offers nothing on half of them.
    ///
    /// - Parameter epoch: Stamped onto every item, so a resolve arriving
    ///   after this list has been superseded can be refused rather than
    ///   answered wrongly. See `LSPCompletion.isCurrent(inEpoch:)`.
    init(_ value: LSPValue, epoch: Int = 0) {
        let defaults = LSPCompletion.ItemDefaults(value["itemDefaults"])
        let raw = value["items"]?.arrayValue ?? value.arrayValue ?? []

        /// The index is the position in what the server sent, not in what
        /// survived parsing: it has to mean the same thing as `sortText`
        /// does to the server.
        self.items = raw.enumerated().compactMap {
            LSPCompletion($0.element, index: $0.offset, defaults: defaults, epoch: epoch)
        }
        self.isIncomplete = value["isIncomplete"]?.boolValue ?? false
        self.itemDefaults = defaults
    }
}

/// What asking for completions ended in.
///
/// `[]` used to mean four different things — no server for this language,
/// the request timing out, the server answering with an error, and the
/// server genuinely having nothing to offer — and a caller could only treat
/// all four as "no suggestions", which is why "the list blinked empty" was
/// never traceable to a cause.
///
/// `.cancelled` is the case that is correctness rather than diagnostics: it
/// means a newer request is already on its way, so the UI must **keep** the
/// list it is showing. Clearing it makes the list vanish under the very
/// keystroke that was refining it.
enum LSPCompletionOutcome: Equatable {
    /// The server answered. The list may still be empty, and an empty
    /// answer is the *only* one that should clear a visible list.
    case list(LSPCompletionList)

    case noServer
    case cancelled
    case timedOut
    case failed(String)

    /// The items, or none.
    ///
    /// For a caller that genuinely only wants a list — but note that
    /// `.cancelled` answers `[]` here too, so anything that clears on empty
    /// has to switch on the case instead of asking this.
    var items: [LSPCompletion] {
        guard case .list(let list) = self else { return [] }
        return list.items
    }

    var isCancelled: Bool { self == .cancelled }
}

/// What asking a server to finish an item ended in.
///
/// Separate from `LSPCompletionOutcome` because the caller's decision is
/// different: there is one case that carries a better item, and every other
/// case means "keep drawing what you already have". Collapsing them to an
/// optional would work, and would lose the two distinctions that matter —
/// `.stale`, which is not an answer at all, and `.unsupported`, which will
/// never become one.
enum LSPResolveOutcome: Equatable {
    case resolved(LSPCompletion)

    /// The list this item came from has been superseded. Nothing was sent.
    /// **Not** "there is no documentation" — see
    /// `LSPCompletion.isCurrent(inEpoch:)` for why the difference is the
    /// whole point.
    case stale

    /// The server answers no resolve at all, so nothing was sent and nothing
    /// ever will be. `kotlin-language-server`'s permanent answer: do not
    /// retry it, and do not draw a spinner waiting for it.
    case unsupported

    case noServer
    case cancelled
    case timedOut
    case failed(String)

    var item: LSPCompletion? {
        guard case .resolved(let item) = self else { return nil }
        return item
    }
}

/// Why completions were asked for — `CompletionContext` on the wire.
///
/// Sent on every request, which is not a detail: `contextSupport: true` with
/// no `context` in the params is a lie neither side can detect.
/// `typescript-language-server` uses the trigger character to decide whether
/// it is completing a member access at all, so the missing context does not
/// fail — it silently answers a different question.
struct LSPCompletionContext: Equatable {
    enum Kind: Int, Equatable {
        /// ⌃Space, and also the first request of a session the user opened
        /// by typing an identifier character. Not kind 3: "incomplete" is a
        /// statement about a list already on screen.
        case invoked = 1

        /// One of the characters the server *advertised*. Claiming a trigger
        /// it never asked for makes it complete in a context it would have
        /// declined.
        case triggerCharacter = 2

        /// A re-request for a list the server marked `isIncomplete`.
        case incomplete = 3
    }

    let kind: Kind
    let triggerCharacter: String?

    var value: LSPValue {
        var object: [String: LSPValue] = ["triggerKind": .integer(kind.rawValue)]
        if let triggerCharacter { object["triggerCharacter"] = .string(triggerCharacter) }
        return .object(object)
    }

    static let invoked = LSPCompletionContext(kind: .invoked, triggerCharacter: nil)
    static let incomplete = LSPCompletionContext(kind: .incomplete, triggerCharacter: nil)

    static func triggered(by character: Character) -> LSPCompletionContext {
        LSPCompletionContext(kind: .triggerCharacter, triggerCharacter: String(character))
    }

    /// Which context a keystroke earns, as a pure decision.
    ///
    /// A trigger character outranks refining an incomplete list: `.` starts a
    /// new session rather than narrowing the one on screen, and it is the
    /// piece of information the server can least afford to be denied.
    /// `typedCharacter` is only honoured when the server advertised it —
    /// that check is the whole reason this is a function and not a literal
    /// at the call site.
    static func decide(
        typedCharacter: Character?,
        isRefiningIncompleteList: Bool,
        support: LSPCompletionCapability?
    ) -> LSPCompletionContext {
        if let typedCharacter, support?.triggerCharacters.contains(typedCharacter) == true {
            return .triggered(by: typedCharacter)
        }
        if isRefiningIncompleteList { return .incomplete }
        return .invoked
    }
}

extension LSPCenter {
    /// What this client tells a server it can do.
    ///
    /// Assembled here rather than by editing `LSPProcess.defaultCapabilities`
    /// for the reason that file's own comment gives: a transport can only
    /// honestly promise what a transport does, and the features being
    /// promised here live in this file. It also keeps the block assertable
    /// without a process anywhere near the test.
    nonisolated static let clientCapabilities: LSPValue = LSPProcess.defaultCapabilities
        .merging(["textDocument": ["completion": completionCapabilities]])

    /// The completion half, kept separate so a test can read it directly.
    ///
    /// Three capabilities are conspicuously *not* here, each because
    /// announcing it fails invisibly rather than loudly:
    ///
    /// - `insertReplaceSupport`: a server would send `InsertReplaceEdit`
    ///   items whose two ranges the accept path does not yet choose between.
    ///   Parsed on the way in anyway — see `LSPCompletion.Edit` — because
    ///   understanding one is free; asking for them is not.
    /// - `commitCharactersSupport`: it promises that typing one of the
    ///   server's characters accepts the selected item. Nothing here does
    ///   that, and a server told otherwise stops sending items it expects to
    ///   be committed that way.
    /// - `completionList.itemDefaults`: sourcekit-lsp knows
    ///   `ItemDefaultsEditRange`, and advertising support for it makes items
    ///   arrive with **no per-item edit at all**. Defaults that arrive
    ///   unbidden are honoured; asking for them would be asking a server to
    ///   stop telling us where its edits go.
    nonisolated static let completionCapabilities: LSPValue = [
        "dynamicRegistration": false,
        "contextSupport": true,
        "completionItem": [
            /// On, and the precondition it waited for is that `CodeSnippet`'s
            /// parser and the tab-stop session are wired into `CodeTextView`:
            /// the marker is consumed now rather than inserted. Announced
            /// before that, a server's `console.log(${1:message})` was typed
            /// into the reader's file literally, placeholders and all.
            ///
            /// Leaving it off was never free either. Measured,
            /// `typescript-language-server` does
            /// `if (isSnippet && !features.completionSnippets) return null` —
            /// so `false` was silently dropping whole items, class members
            /// among them, not merely their placeholders.
            ///
            /// The claim is only honest while **`insertTextFormat == 2` stays
            /// the sole test for snippet-ness** (`LSPCompletion.isSnippet`).
            /// Absent means plain text, and in a plain item a `$` is a dollar
            /// sign: inferring from the text instead would mutilate the
            /// insertion of every item that merely contains one.
            "snippetSupport": true,
            /// The "origin" column: this is what makes
            /// `typescript-language-server` populate
            /// `labelDetails.description` with the module a symbol comes
            /// from.
            "labelDetailsSupport": true,
            "preselectSupport": true,
            "deprecatedSupport": true,
            "tagSupport": ["valueSet": [1]],
            /// Plaintext first, unlike hover: a completion's documentation is
            /// drawn as a plain string in a small panel, and raw `**` in it
            /// is worse than a server's own flattening.
            "documentationFormat": ["plaintext", "markdown"],
            "insertReplaceSupport": false,
            "commitCharactersSupport": false,
            /// Only what the accept path and the documentation pane consume,
            /// and exactly what `LSPCompletion.merging(resolved:)` will take
            /// from the reply. A property listed here is a promise that its
            /// absence from the first answer is fine, so listing one nothing
            /// reads invites a server to withhold it — and listing one the
            /// merge would then discard is the same lie in reverse.
            "resolveSupport": [
                "properties": ["documentation", "detail", "additionalTextEdits", "command"]
            ]
        ],
        "completionItemKind": ["valueSet": .array((1...25).map(LSPValue.integer))]
    ]
}
