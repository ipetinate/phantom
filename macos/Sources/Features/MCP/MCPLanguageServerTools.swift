import Foundation

/// The two tools that act on a language server rather than read one.
///
/// Kept apart from ``MCPDiagnosticTools`` because the split is the point:
/// that file answers questions and asks the reader nothing, and these two
/// change the app. A restart interrupts a running process; a configure writes
/// a setting that outlives the session. Sharing a file with the read tools
/// would make it easy to reason about the group as if it were all one kind.
///
/// ## Why the loop needs both
///
/// A diagnostic tells an agent that Vue's `<script>` block is unserved because
/// a TypeScript plugin is missing. The fix is a value in
/// `initializationOptions`. Without `configure_language_server` it can only
/// describe the fix; without `restart_language_server` the fix sits in a
/// setting that takes effect the next time the server starts, which used to
/// mean relaunching the app. Either one alone leaves the reader finishing the
/// job by hand.
@MainActor
enum MCPLanguageServerTools {
    static var all: [MCPToolHandler] { [restartServer, configureServer] }

    /// How long a refused restart makes the next one wait.
    ///
    /// Matches `MCPPermissionStore`'s own cooldown, and for the same reason:
    /// an agent that gets nothing back from a retry retries, and a server
    /// restarted in a loop is a server that never finishes starting. The
    /// refusal says how much longer, because a "no" with no number in it
    /// teaches the caller nothing and it tries again immediately.
    static let cooldown: TimeInterval = 60

    private static var restartedAt: [String: Date] = [:]

    // MARK: Restart

    static var restartServer: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "restart_language_server",
                description: """
                    Restart a language server and re-announce every file this app has \
                    open to it. Use it after you change something the server reads at \
                    startup — an installed dependency, a config file, its \
                    initializationOptions — to make the change take effect and to check \
                    whether it worked. Call list_language_servers afterwards to see \
                    whether it came up, and list_diagnostics to see what it now says. \
                    One restart per server per minute.
                    """,
                schema: MCPSchema.object([
                    "server": MCPSchema.string(
                        "The server's name or command, as list_language_servers "
                        + "reported it."),
                ], required: ["server"]))
        ) { context, answer in
            guard let named = context.string("server") else {
                return answer(.refused(
                    "restart_language_server needs a `server`. Call "
                    + "list_language_servers and pass a `name` from it."))
            }

            guard let definition = server(named) else {
                return answer(.refused(unknownServer(named)))
            }

            if let last = restartedAt[definition.command] {
                let waited = Date().timeIntervalSince(last)
                if waited < cooldown {
                    let left = Int((cooldown - waited).rounded(.up))
                    return answer(.refused(
                        "\(definition.displayName) was restarted \(Int(waited)) second"
                        + "\(Int(waited) == 1 ? "" : "s") ago. Wait \(left) more second"
                        + "\(left == 1 ? "" : "s"). Restarting in a loop is why this "
                        + "limit exists — read list_language_servers to see whether the "
                        + "last one came up before asking for another."))
                }
            }

            restartedAt[definition.command] = Date()
            let outcome = LSPRestart.restart(definition)

            answer(.json(.object([
                "server": .string(definition.displayName),
                "stopped": .number(Double(outcome.stopped)),
                "reannounced": .number(Double(outcome.reannounced)),
                "message": .string(
                    "\(definition.displayName): stopped \(outcome.stopped) workspace"
                    + "\(outcome.stopped == 1 ? "" : "s") and re-announced "
                    + "\(outcome.reannounced) open file"
                    + "\(outcome.reannounced == 1 ? "" : "s"). It starts again on the "
                    + "next request, so call list_language_servers to see whether it "
                    + "came up."),
            ])))
        }
    }

    // MARK: Configure

    static var configureServer: MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "configure_language_server",
                description: """
                    Set a language server's initializationOptions — the JSON it is \
                    handed at startup. Use it to fix a server that runs but cannot \
                    interpret a file, which is what a missing plugin looks like: Vue's \
                    <script> block needing the TypeScript plugin is the case this \
                    exists for. The reader is asked before anything is written, and \
                    they see the JSON. It refuses to overwrite options the reader typed \
                    themselves, and the setting applies in every project — it is the \
                    app's configuration, not this project's. Restart the server \
                    afterwards for it to take effect.
                    """,
                schema: MCPSchema.object([
                    "server": MCPSchema.string(
                        "The server's name or command, as list_language_servers "
                        + "reported it."),
                    "initialization_options": MCPSchema.string(
                        "The JSON object to send at startup. Must be an object. Pass an "
                        + "empty string to go back to this app's own default."),
                ], required: ["server", "initialization_options"]))
        ) { context, answer in
            guard let named = context.string("server") else {
                return answer(.refused(
                    "configure_language_server needs a `server`. Call "
                    + "list_language_servers and pass a `name` from it."))
            }

            guard let definition = server(named) else {
                return answer(.refused(unknownServer(named)))
            }

            guard let json = context.string("initialization_options") else {
                return answer(.refused(
                    "configure_language_server needs `initialization_options`: the JSON "
                    + "object to hand the server at startup, or an empty string to "
                    + "restore this app's default."))
            }

            let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)

            /// Validated with the app's own parser before the reader is asked
            /// anything. A question about a value that could never be stored
            /// spends their attention on a change that cannot happen.
            if !trimmed.isEmpty {
                if case .failure(let reason) = LSPCenter.parseInitializationOptions(trimmed) {
                    return answer(.refused(
                        "That is not initializationOptions this app can send: \(reason). "
                        + "Nothing was changed and the reader was not asked."))
                }
            }

            let existing = LSPServerOverrideStore.override(for: definition.command)
            let current = existing?.initializationOptionsJSON
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            /// The reader's own value is not yours to replace. There is no
            /// history in the store, so overwriting it is not undoable — and
            /// the case this tool exists for is a server sitting on the
            /// defaults, which is exactly the case this still allows.
            if !current.isEmpty, current != trimmed {
                return answer(.refused(
                    "\(definition.displayName) already has initializationOptions the "
                    + "reader set by hand, and replacing them cannot be undone. Tell "
                    + "them what to change instead — it is in Settings, under "
                    + "Languages. What is there now is:\n\(current)"))
            }

            if current == trimmed {
                return answer(.text(
                    "\(definition.displayName) already has exactly those "
                    + "initializationOptions. Nothing to change."))
            }

            let tab = context.callerSurface.flatMap { MCPTerminalTools.tab(for: $0) }
            MCPPermissionStore.shared.decide(
                MCPPermission.Request(
                    capability: .configure,
                    surface: context.callerSurface,
                    group: tab.flatMap {
                        SidebarGroupStore.shared
                            .resolveGroup(surfaceId: context.callerSurface!, pwd: $0.pwd)?
                            .id.uuidString
                    }),
                client: context.client,
                clientName: context.clientName,
                tabTitle: tab.map { MCPTerminalTools.displayTitle($0) },
                detail: diff(definition, to: trimmed)
            ) { granted in
                guard granted else {
                    return answer(.refused(
                        "The reader did not allow changing how "
                        + "\(definition.displayName) starts. Nothing was written."))
                }

                var override = existing ?? LSPServerOverride()
                override.initializationOptionsJSON = trimmed
                LSPServerOverrideStore.set(override, for: definition.command)

                answer(.json(.object([
                    "server": .string(definition.displayName),
                    "message": .string(
                        trimmed.isEmpty
                            ? "\(definition.displayName) is back on this app's own "
                            + "default initializationOptions. Restart it for that to "
                            + "take effect."
                            : "\(definition.displayName) will be started with those "
                            + "initializationOptions from now on, in every project. "
                            + "Call restart_language_server to apply it to the session "
                            + "already running."),
                ])))
            }
        }
    }

    /// The sentence the reader decides on: which server, and what the value
    /// becomes.
    ///
    /// Both sides, because "set initializationOptions" says nothing about what
    /// is being replaced — and going back to the default is a change too, one
    /// that reads as harmless until you know the default is what made Vue work.
    static func diff(_ definition: LSPServerDefinition, to json: String) -> String {
        let now = LSPServerOverrideStore.override(for: definition.command)?
            .initializationOptionsJSON
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let before = now.isEmpty ? "this app's own default" : now
        let after = json.isEmpty ? "this app's own default" : json
        return "\(definition.displayName) — initializationOptions\n\nNow:\n\(before)"
            + "\n\nProposed:\n\(after)"
    }

    // MARK: Naming a server

    /// A server by the name a caller would have, which is either the one shown
    /// or the command underneath it.
    ///
    /// Both, because `list_language_servers` reports both and a model given two
    /// strings will use either. Matched case-insensitively on the name: it is
    /// prose in the interface, and refusing "typescript (npm)" for its capital
    /// letters would be a refusal about nothing.
    static func server(_ named: String) -> LSPServerDefinition? {
        let wanted = named.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return LSPServerRegistry.distinctServers.first {
            $0.displayName.lowercased() == wanted || $0.command.lowercased() == wanted
        }
    }

    static func unknownServer(_ named: String) -> String {
        let names = LSPServerRegistry.distinctServers.map(\.displayName).joined(separator: ", ")
        return "“\(named)” is not a language server this app knows. Call "
            + "list_language_servers for what there is. Right now: \(names)."
    }
}
