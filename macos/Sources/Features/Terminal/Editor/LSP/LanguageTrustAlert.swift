#if os(macOS)
import AppKit

/// Asks whether a contributed language server may be launched.
///
/// Modelled on `UntrustedURLAlert`, down to the details that look cosmetic
/// and are not: `NSAlert` with a warning icon, the thing being approved in a
/// monospaced, selectable, **non-editable** accessory view rather than in
/// the prose, a sheet on the key window with a modal fallback when there
/// isn't one, and **refusal as the default action** — the safe answer is the
/// one that happens when somebody hits Return without reading.
///
/// Every manifest-supplied string here goes through
/// `UntrustedURL.escapingUnsafeScalars`. That is not hygiene. Without it the
/// prompt is forgeable: a `U+202E` in `name` reverses the text that follows
/// it, and a newline in `installHint` adds a line that can restate the
/// command as something other than the command being approved. A dialog that
/// displays one thing and approves another is worse than no dialog.
///
/// The text is built by pure functions so the escaping is testable without a
/// window — the test host has no event loop, and anything that reaches
/// `runModal` or `orderFront` hangs the whole suite.
enum LanguageTrustAlert {
    /// Everything shown, gathered before any window exists.
    struct Request: Equatable {
        let extensionName: String
        let extensionID: String
        let publisher: String
        let extensionVersion: String
        let languageName: String
        let command: String
        let arguments: [String]

        /// Where `PATH` resolution landed. Shown because it, not the name,
        /// is what will actually run.
        let resolvedPath: String

        let manifestPath: String
        let change: LanguageTrust.Change
    }

    // MARK: Text

    static func messageText(for request: Request) -> String {
        "Run a Language Server from \u{201c}\(escaped(request.extensionName))\u{201d}?"
    }

    /// The prose beside the icon.
    ///
    /// It says the exposure plainly, because no wording makes it smaller:
    /// this app is not sandboxed, so an approved server has everything the
    /// person running Phantom has. It then states the invalidation rule,
    /// without which remembering the answer would not be defensible — an
    /// answer the user cannot tell the scope of is not consent.
    static func informativeText(for request: Request) -> String {
        var lines: [String] = []

        let publisher = request.publisher.isEmpty
            ? "an unidentified publisher"
            : "\u{201c}\(escaped(request.publisher))\u{201d}"
        lines.append("""
        This extension, from \(publisher), wants to start a language server \
        for \(escaped(request.languageName)).
        """)

        lines.append("""
        The program below runs as you, with access to your files, your \
        keychain and the network. Phantom does not contain it once it starts.
        """)

        if let change = changeText(for: request.change) { lines.append(change) }

        lines.append("""
        Phantom remembers this answer and asks again if the extension's \
        manifest changes, if it asks for a different command, or if either \
        moves. It does not ask again when the program itself is updated. \
        You can change your answer in Settings.
        """)

        return lines.joined(separator: "\n\n")
    }

    static func changeText(for change: LanguageTrust.Change) -> String? {
        switch change {
        case .firstRun:
            return nil
        case .manifestChanged:
            return "The manifest has changed since you last answered this."
        case .commandChanged(let previous):
            return "It previously asked to run \u{201c}\(escaped(previous))\u{201d}."
        case .commandPathChanged(let previous):
            return "That command previously resolved to \(escaped(previous))."
        case .manifestMoved(let previous):
            return "The manifest was previously at \(escaped(previous))."
        }
    }

    /// The monospaced block: what runs, where it is, and which file asked.
    static func detailText(for request: Request) -> String {
        let invocation = ([request.command] + request.arguments)
            .map(escaped)
            .joined(separator: " ")

        var lines = ["Command:   \(invocation)"]
        lines.append("Resolves:  \(escaped(request.resolvedPath))")
        lines.append("Manifest:  \(escaped(request.manifestPath))")
        lines.append("Extension: \(escaped(request.extensionID))")
        if !request.extensionVersion.isEmpty {
            lines.append("Version:   \(escaped(request.extensionVersion))")
        }
        return lines.joined(separator: "\n")
    }

    /// The one escape used for every string in this file.
    ///
    /// `UntrustedURL` owns the rule; this file only names it. A second
    /// implementation of "which scalars are dangerous to display" is a
    /// second implementation to keep in step, and the one that drifts is the
    /// one nobody is looking at.
    private static func escaped(_ raw: String) -> String {
        UntrustedURL.escapingUnsafeScalars(raw)
    }

    // MARK: Presentation

    @MainActor
    static func requestApproval(_ request: Request) async -> Bool {
        await withCheckedContinuation { continuation in
            present(request) { continuation.resume(returning: $0) }
        }
    }

    /// Shows the prompt.
    ///
    /// The first button added is the default one, and refusing is
    /// deliberately it — the same choice `UntrustedURLAlert` makes for
    /// Cancel, and for the same reason: the safe answer has to be the one
    /// that happens when Return is pressed without reading.
    @MainActor
    static func present(_ request: Request, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(named: NSImage.cautionName)
        alert.messageText = messageText(for: request)
        alert.informativeText = informativeText(for: request)
        alert.accessoryView = detailView(detailText(for: request))

        alert.addButton(withTitle: "Don't Run")
        alert.addButton(withTitle: "Run Language Server")

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .alertSecondButtonReturn)
        }

        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private static func detailView(_ text: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 110))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = text
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        return scrollView
    }
}

/// The gate itself: store, verdict, prompt and record in one call, so the
/// only place that creates a language-server process has one line to add
/// rather than a policy to reimplement.
///
/// It gates `Process.run` and nothing else. A refusal here costs the file
/// its server; it keeps its highlighting, its comment toggling, its keywords
/// and its buffer-word completion, because none of those needed a process.
enum LanguageTrustGate {
    /// Whether this definition may be launched, asking the user when the
    /// answer is not already recorded.
    ///
    /// `resolvedPath` is the caller's: it has already located the command to
    /// decide whether the server is installed at all, and resolving twice
    /// could resolve differently.
    @MainActor
    static func allowsLaunch(
        of definition: LSPServerDefinition,
        resolvedPath: String,
        workspaceRoot: String?
    ) async -> Bool {
        guard case .manifest(let provenance) = definition.origin else { return true }

        let subject = LanguageTrust.Subject(
            origin: definition.origin,
            digest: provenance.digest,
            command: definition.command,
            resolvedPath: resolvedPath,
            workspaceRoot: workspaceRoot
        )

        switch LanguageTrust.verdict(
            for: subject,
            record: LanguageTrustStore.record(for: provenance.extensionID)
        ) {
        case .allow:
            return true

        case .deny:
            return false

        case .ask(let change):
            let approved = await LanguageTrustAlert.requestApproval(
                request(for: definition, subject: subject, change: change)
            )
            LanguageTrustStore.remember(approved ? .allowed : .refused, for: subject)
            return approved
        }
    }

    /// Fills the prompt out of the catalog, which is where the extension's
    /// own name, publisher and version live — the definition carries only
    /// what launching needs.
    @MainActor
    private static func request(
        for definition: LSPServerDefinition,
        subject: LanguageTrust.Subject,
        change: LanguageTrust.Change
    ) -> LanguageTrustAlert.Request {
        guard case .manifest(let provenance) = definition.origin else {
            preconditionFailure("a prompt is only built for a manifest-supplied server")
        }
        let contributed = LanguageResolver.shared.catalog
            .contribution(forLanguageID: definition.languageID)

        return LanguageTrustAlert.Request(
            extensionName: contributed?.extensionName ?? provenance.extensionID,
            extensionID: provenance.extensionID,
            publisher: contributed?.publisher ?? "",
            extensionVersion: contributed?.extensionVersion ?? "",
            languageName: contributed?.language.displayName ?? definition.languageID,
            command: definition.command,
            arguments: definition.arguments,
            resolvedPath: subject.resolvedPath,
            manifestPath: provenance.manifestPath,
            change: change
        )
    }
}
#endif
