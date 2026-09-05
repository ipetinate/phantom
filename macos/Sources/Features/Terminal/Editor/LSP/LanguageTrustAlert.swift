#if os(macOS)
import AppKit

/// Asks whether a contributed program — a language server, or a formatter —
/// may be launched.
///
/// Shown through `ConfirmationPrompt`, and it keeps the details that look
/// cosmetic and are not: a warning icon, the thing being approved in
/// monospaced, selectable rows rather than in the prose, a sheet on the key
/// window with a modal fallback when there isn't one, and **refusal as the
/// default action** — the safe answer is the one that happens when somebody
/// hits Return without reading.
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

        var role: Role = .languageServer

        enum Role: Equatable {
            case languageServer
            case formatter(tool: String)
        }
    }

    // MARK: Text

    static func messageText(for request: Request) -> String {
        let program: String
        switch request.role {
        case .languageServer: program = "a Language Server"
        case .formatter: program = "a Formatter"
        }
        return "Run \(program) from \u{201c}\(escaped(request.extensionName))\u{201d}?"
    }

    static func confirmButtonTitle(for request: Request) -> String {
        switch request.role {
        case .languageServer: return "Run Language Server"
        case .formatter: return "Run Formatter"
        }
    }

    /// The prose beside the icon.
    ///
    /// It says the exposure plainly, because no wording makes it smaller:
    /// this app is not sandboxed, so an approved server has everything the
    /// person running Phantom has. It then states the invalidation rule,
    /// without which remembering the answer would not be defensible — an
    /// answer the user cannot tell the scope of is not consent.
    static func informativeText(for request: Request) -> String {
        [consequenceText(for: request), changeText(for: request.change), rememberText()]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    static func consequenceText(for request: Request) -> String {
        let publisher = request.publisher.isEmpty
            ? "an unidentified publisher"
            : "\u{201c}\(escaped(request.publisher))\u{201d}"
        let exposure = "it runs as you, with access to your files, your keychain and the network."
        switch request.role {
        case .languageServer:
            return """
            This extension, from \(publisher), wants to start a language server \
            for \(escaped(request.languageName)) \u{2014} \(exposure)
            """
        case .formatter(let tool):
            return """
            This extension, from \(publisher), wants to run \(escaped(tool)) to \
            format \(escaped(request.languageName)) files \u{2014} \(exposure)
            """
        }
    }

    static func rememberText() -> String {
        """
        Phantom remembers this answer and asks again if the manifest, the \
        command or its path changes. You can change it in Settings.
        """
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

    static func detailRows(for request: Request) -> [ConfirmationPrompt.Detail] {
        let invocation = ([request.command] + request.arguments)
            .map(escaped)
            .joined(separator: " ")

        var rows = [
            ConfirmationPrompt.Detail(
                label: "Publisher",
                value: request.publisher.isEmpty ? "Unidentified" : escaped(request.publisher)
            ),
            ConfirmationPrompt.Detail(label: "Command", value: invocation),
            ConfirmationPrompt.Detail(label: "Resolves to", value: escaped(request.resolvedPath)),
            ConfirmationPrompt.Detail(label: "Manifest", value: escaped(request.manifestPath)),
            ConfirmationPrompt.Detail(label: "Extension", value: escaped(request.extensionID)),
        ]
        if !request.extensionVersion.isEmpty {
            rows.append(.init(label: "Version", value: escaped(request.extensionVersion)))
        }
        return rows
    }

    /// The monospaced block: what runs, where it is, and which file asked.
    static func detailText(for request: Request) -> String {
        prompt(for: request).detailText
    }

    static func prompt(for request: Request) -> ConfirmationPrompt {
        ConfirmationPrompt(
            title: messageText(for: request),
            consequence: consequenceText(for: request),
            change: changeText(for: request.change),
            details: detailRows(for: request),
            primary: .init(title: confirmButtonTitle(for: request)),
            secondary: .init(title: "Don't Run", isDefault: true),
            remember: rememberText()
        )
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
    /// Refusing is deliberately the default action — the same choice
    /// `UntrustedURLAlert` makes for Cancel, and for the same reason: the
    /// safe answer has to be the one that happens when Return is pressed
    /// without reading.
    @MainActor
    static func present(_ request: Request, completion: @escaping (Bool) -> Void) {
        ConfirmationPrompt.present(prompt(for: request), on: NSApp.keyWindow, completion: completion)
    }
}

/// The gate itself: store, verdict, prompt and record in one call, so the
/// two places that create a process from a manifest's command — the
/// language-server start and the external-formatter run — have one line to
/// add rather than a policy to reimplement.
///
/// It gates `Process.run` and nothing else. A refusal here costs the file
/// its server or its formatter; it keeps its highlighting, its comment
/// toggling, its keywords and its buffer-word completion, because none of
/// those needed a process.
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
        return await decide(subject, extensionID: provenance.extensionID) { change in
            request(for: definition, subject: subject, change: change)
        }
    }

    @MainActor
    static func allowsRun(
        of formatter: ExternalFormatter,
        resolvedPath: String,
        workspaceRoot: String?
    ) async -> Bool {
        guard case .manifest(let provenance) = formatter.origin else { return true }

        let subject = LanguageTrust.Subject(
            origin: formatter.origin,
            digest: provenance.digest,
            command: formatter.command,
            resolvedPath: resolvedPath,
            workspaceRoot: workspaceRoot
        )
        return await decide(subject, extensionID: provenance.extensionID) { change in
            request(for: formatter, provenance: provenance, subject: subject, change: change)
        }
    }

    @MainActor
    private static func decide(
        _ subject: LanguageTrust.Subject,
        extensionID: String,
        request: (LanguageTrust.Change) -> LanguageTrustAlert.Request
    ) async -> Bool {
        switch LanguageTrust.verdict(
            for: subject,
            record: LanguageTrustStore.record(for: extensionID)
        ) {
        case .allow:
            return true

        case .deny:
            return false

        case .ask(let change):
            let approved = await LanguageTrustAlert.requestApproval(request(change))
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

    @MainActor
    private static func request(
        for formatter: ExternalFormatter,
        provenance: ExtensionProvenance,
        subject: LanguageTrust.Subject,
        change: LanguageTrust.Change
    ) -> LanguageTrustAlert.Request {
        let contributed = LanguageResolver.shared.catalog.formatters
            .first { $0.provenance == provenance && $0.id == formatter.id }

        return LanguageTrustAlert.Request(
            extensionName: contributed?.extensionName ?? provenance.extensionID,
            extensionID: provenance.extensionID,
            publisher: contributed?.publisher ?? "",
            extensionVersion: contributed?.extensionVersion ?? "",
            languageName: formatter.extensions.sorted().map { "." + $0 }.joined(separator: ", "),
            command: formatter.command,
            arguments: formatter.arguments,
            resolvedPath: subject.resolvedPath,
            manifestPath: provenance.manifestPath,
            change: change,
            role: .formatter(tool: formatter.displayName)
        )
    }
}
#endif
