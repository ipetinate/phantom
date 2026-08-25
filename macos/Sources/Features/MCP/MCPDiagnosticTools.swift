import Foundation

/// What the app already knows is wrong, offered to the agent that can fix it.
///
/// The reader used to be the transport: a language server refused a file, or
/// Prettier could not parse it, and the sentence explaining why got copied
/// into a chat by hand. Everything here already existed in the app — the
/// servers' findings, the reason one did not start, the formatter's
/// complaint — and none of it was reachable by the thing best placed to act
/// on it.
///
/// ## Consent: the broad call never asks, and never leaves the project
///
/// A diagnostic is content in a small dose. A type error prints the offending
/// expression, so `list_diagnostics` is a reading channel however narrow, and
/// the editor tools' own rule — no second way to read with no consent
/// attached — applies.
///
/// The line drawn is the caller's own working directory. Inside it, nothing
/// is asked: the caller is an agent running as the reader, in the reader's
/// project, holding tools that already read those files directly, so a
/// diagnostic about one discloses nothing new. Outside it, the `read` grant
/// is required — the same grant the scrollback needs, rather than a fourth
/// capability nobody can hold in their head.
///
/// That makes the shape of the two calls different on purpose:
///
/// - **No path**: answers only for files under the caller's directory, says
///   how many it withheld, and never raises a prompt. This is the call an
///   agent makes to orient itself, and a prompt there would be a prompt on
///   every turn.
/// - **A path outside the directory**: asks once. Naming a file is a
///   deliberate act, which is exactly when a question is worth the reader's
///   attention.
///
/// ## Positions are one-based here and zero-based in the protocol
///
/// LSP counts lines and characters from zero. Compilers, stack traces,
/// `reveal_line` and every reader count from one. The conversion happens once,
/// here, and the descriptions say so — an off-by-one in a line number sends an
/// agent to edit the wrong line, and it looks like a plausible answer while
/// doing it.
@MainActor
enum MCPDiagnosticTools {
    static var all: [MCPToolHandler] { [listDiagnostics, listLanguageServers] }

    /// How much of a server's stderr comes back.
    ///
    /// The whole tail is a hundred lines and most of it is startup noise. The
    /// reason a server is unwell is at the end, and an answer long enough to
    /// bury it is an answer that gets skimmed.
    private static let logTail = 40

    // MARK: Diagnostics

    static var listDiagnostics: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "list_diagnostics",
                description: """
                    List what the language servers and the formatter found wrong in the \
                    files this window has open: the errors and warnings the reader sees \
                    underlined, and the reason a format attempt failed. Use it before you \
                    guess at a problem and after you change code, to check whether you \
                    fixed it. Lines and columns come back one-based, as compilers and \
                    stack traces count them. Called with no path it answers only for \
                    files under this tab's own directory and asks the reader nothing; \
                    naming a file outside that directory needs the reader's permission \
                    once.
                    """,
                schema: MCPSchema.object([
                    "path": MCPSchema.string(
                        "Absolute path of one open file. Omit it for every file under "
                        + "this tab's directory."),
                    "severity": MCPSchema.enumeration(
                        "The least severe level to include. \"warning\" returns errors "
                        + "and warnings, \"error\" returns errors alone. Defaults to "
                        + "\"hint\", which is everything.",
                        Severity.allCases.map(\.rawValue)),
                ]))
        ) { context, answer in
            let threshold = Severity(rawValue: context.string("severity")?.lowercased() ?? "")
                ?? .hint

            guard let asked = context.string("path") else {
                return answer(.json(inProject(threshold, context: context)))
            }

            guard let path = MCPEditorTools.absolutePath(asked) else {
                return answer(.refused(
                    MCPEditorTools.pathRefusal(asked, for: "list_diagnostics")))
            }

            if isInCallerProject(path, context: context) {
                return answer(.json(.object([
                    "diagnostics": .array(diagnostics(for: path, atLeast: threshold)),
                    "path": .string(path),
                ])))
            }

            guard let surface = context.callerSurface,
                  let tab = MCPTerminalTools.tab(for: surface)
            else {
                return answer(.refused(
                    "\(path) is outside this tab's directory, and this call cannot be "
                    + "traced to a tab, so there is nobody to ask for permission. Name a "
                    + "file inside the project instead."))
            }

            MCPTerminalTools.allow(.read, for: tab, id: surface, context: context) { granted in
                guard granted else {
                    return answer(.refused(
                        "\(path) is outside this tab's directory, and the reader did not "
                        + "grant permission to read from outside it. Files under "
                        + "\(tab.pwd) need no permission — call this again without a path "
                        + "to see them."))
                }
                answer(.json(.object([
                    "diagnostics": .array(diagnostics(for: path, atLeast: threshold)),
                    "path": .string(path),
                ])))
            }
        }
    }

    /// Every diagnostic under the caller's own directory, and a count of what
    /// was left out.
    ///
    /// The count matters more than it looks. Silence and "nothing outside your
    /// project has a problem" read identically to a caller, and one of them is
    /// a lie it would act on.
    private static func inProject(_ threshold: Severity, context: MCPToolContext) -> JSONValue {
        let root = callerDirectory(context)
        var inside: [JSONValue] = []
        var withheld = 0

        for path in paths() {
            guard !diagnostics(for: path, atLeast: threshold).isEmpty else { continue }
            if let root, isInside(path, root: root) {
                inside += diagnostics(for: path, atLeast: threshold)
            } else {
                withheld += 1
            }
        }

        var answer: [String: JSONValue] = [
            "diagnostics": .array(inside),
            "directory": root.map { .string($0) } ?? .null,
        ]
        if withheld > 0 {
            answer["files_withheld"] = .number(Double(withheld))
            answer["note"] = .string(
                "\(withheld) file\(withheld == 1 ? "" : "s") with diagnostics "
                + "\(withheld == 1 ? "is" : "are") open from outside this tab's directory "
                + "and \(withheld == 1 ? "was" : "were") left out. Name one by path to ask "
                + "the reader for it.")
        }
        return .object(answer)
    }

    /// Every path anything has something to say about.
    private static func paths() -> [String] {
        let lsp = Set(LSPCenter.shared.diagnostics.keys)
        return Array(lsp.union(FormatFailureStore.shared.all.keys)).sorted()
    }

    /// One file's findings, from both sources, in one vocabulary.
    private static func diagnostics(for path: String, atLeast threshold: Severity) -> [JSONValue] {
        var items = (LSPCenter.shared.diagnostics[path] ?? [])
            .filter { Severity($0.severity).rank <= threshold.rank }
            .map { item in
                JSONValue.object([
                    "path": .string(path),
                    "line": .number(Double(item.range.start.line + 1)),
                    "column": .number(Double(item.range.start.character + 1)),
                    "end_line": .number(Double(item.range.end.line + 1)),
                    "end_column": .number(Double(item.range.end.character + 1)),
                    "severity": .string(Severity(item.severity).rawValue),
                    "message": .string(item.message),
                    "source": item.source.map { .string($0) } ?? .null,
                ])
            }

        /// The formatter's complaint is an error about the whole file: it
        /// could not parse it, so it has no line of its own to stand on. It
        /// is reported at line 1 rather than left out, because a file that
        /// will not format is exactly what the caller was asked to fix.
        if threshold.rank >= Severity.error.rank,
           let failure = FormatFailureStore.shared.failure(for: path) {
            items.append(.object([
                "path": .string(path),
                "line": .number(1),
                "column": .number(1),
                "severity": .string(Severity.error.rawValue),
                "message": .string(failure.message),
                "source": .string("formatter"),
            ]))
        }

        return items
    }

    // MARK: Servers

    static var listLanguageServers: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "list_language_servers",
                description: """
                    List the language servers this app knows: what each one is called, \
                    whether it is running, and the reason if it is not — plus the command \
                    and arguments it launches with, whether the reader has overridden \
                    them, and the tail of its own error output. Use it when a file has no \
                    diagnostics, no completion or no jump-to-definition and you need to \
                    know whether the server is missing, unapproved, misconfigured or \
                    simply not installed. This reports configuration rather than code, so \
                    it asks the reader nothing.
                    """,
                schema: MCPSchema.object([:]))
        ) { _, answer in
            let servers = LSPServerRegistry.distinctServers.map { definition in
                let effective = LSPCenter.effectiveDefinition(definition)
                let snapshot = LSPCenter.shared.status(for: definition)
                let override = LSPServerOverrideStore.override(for: definition.command)
                let log = LSPCenter.shared.log(for: definition).suffix(logTail)

                return JSONValue.object([
                    "name": .string(definition.displayName),
                    "language": .string(definition.languageID),
                    "state": .string(state(snapshot.state)),
                    "reason": reason(snapshot.state),
                    "command": .string(effective.command),
                    "arguments": .array(effective.arguments.map { .string($0) }),
                    "active_workspaces": .number(Double(snapshot.activeWorkspaceCount)),
                    "overridden_by_reader": .bool(override?.isEmpty == false),
                    "install_hint": .string(definition.installHint),
                    "log": .array(log.map { .string($0) }),
                ])
            }

            answer(.json(.object([
                "servers": .array(servers),
                "count": .number(Double(servers.count)),
            ])))
        }
    }

    private static func state(_ state: LSPServerStatusSnapshot.State) -> String {
        switch state {
        case .unknown: return "unknown"
        case .notInstalled: return "not_installed"
        case .installed: return "installed"
        case .starting: return "starting"
        case .running: return "running"
        case .error: return "error"
        }
    }

    /// The sentence behind an error state, and null for every other one.
    ///
    /// An empty log is not evidence of health: a server that reports its
    /// failures through the protocol rather than through stderr looks
    /// perfectly well from the outside, which is a mistake a sheet in this app
    /// made before. The state is what says whether something is wrong; the
    /// reason and the log only say what.
    private static func reason(_ state: LSPServerStatusSnapshot.State) -> JSONValue {
        guard case .error(let reason) = state else { return .null }
        return .string(reason)
    }

    // MARK: The caller's own patch of the filesystem

    private static func callerDirectory(_ context: MCPToolContext) -> String? {
        guard let surface = context.callerSurface else { return nil }
        return MCPTerminalTools.tab(for: surface)?.pwd
    }

    private static func isInCallerProject(_ path: String, context: MCPToolContext) -> Bool {
        guard let root = callerDirectory(context) else { return false }
        return isInside(path, root: root)
    }

    /// Whether a path sits under a directory.
    ///
    /// Compared as path components rather than as a string prefix: `/a/bc` has
    /// the string `/a/b` as its prefix and is not inside it, and a rule that
    /// got that wrong would hand out diagnostics for a sibling project
    /// without ever asking.
    static func isInside(_ path: String, root: String) -> Bool {
        let parts = (path as NSString).standardizingPath.split(separator: "/")
        let rootParts = (root as NSString).standardizingPath.split(separator: "/")
        guard rootParts.count <= parts.count else { return false }
        return Array(parts.prefix(rootParts.count)) == Array(rootParts)
    }

    // MARK: Severity, as a word

    /// Severity for a caller that writes prompts, not protocol integers.
    ///
    /// `rank` mirrors LSP's own ordering, where 1 is the most severe, so a
    /// threshold reads as "this bad or worse" with a single comparison.
    enum Severity: String, CaseIterable {
        case error
        case warning
        case information
        case hint

        var rank: Int {
            switch self {
            case .error: return 1
            case .warning: return 2
            case .information: return 3
            case .hint: return 4
            }
        }

        init(_ severity: LSPDiagnostic.Severity) {
            switch severity {
            case .error: self = .error
            case .warning: self = .warning
            case .information: self = .information
            case .hint: self = .hint
            }
        }
    }
}
