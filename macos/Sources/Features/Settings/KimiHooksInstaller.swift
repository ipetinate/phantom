import Foundation

/// Installs the hook that reports Kimi Code's session state to the sidebar.
///
/// Two halves, the same two every agent here has: a script Phantom owns, and
/// entries in the agent's own configuration that point at it.
///
/// **The configuration is TOML, and it is the reader's.** `~/.kimi-code/
/// config.toml` holds everything about Kimi — model, permissions, MCP servers,
/// their own hooks — and TOML carries `#` comments that no parse-and-write
/// round trip preserves. So the file is edited as *text*, line by line, and
/// every line that is not ours is copied through untouched. That is the same
/// decision `CodexMCPInstaller` records for the same file format.
///
/// **Identifying our own entries is different here.** Codex's MCP entry is a
/// named table, `[mcp_servers.phantom]`, so it can be found by its name.
/// Kimi's hooks are an *array* of tables — every one of them is spelled
/// `[[hooks]]` — so a block is ours when the `command` inside it points at the
/// script this app installed, and by nothing else. An entry a reader wrote by
/// hand that happens to sit next to ours is left alone.
///
/// **The payload needs no guessing.** Kimi documents the JSON its hooks
/// receive on stdin — `hook_event_name`, `session_id`, `session_title`,
/// `client_type`, `cwd` — so the script reads the one key it needs rather than
/// trying five spellings the way the Codex script has to.
@MainActor
enum KimiHooksInstaller {
    static let scriptName = TabStateScript.fileName

    /// `KIMI_CODE_HOME` relocates Kimi's whole directory, and the reader who
    /// set it did so to keep this out of their home. Writing to the default
    /// anyway would install a hook the agent never reads.
    nonisolated static var kimiDir: URL {
        AgentRegistry.kimiHome.resolve()
    }

    static var scriptURL: URL { kimiDir.appendingPathComponent(scriptName) }
    static var configURL: URL { kimiDir.appendingPathComponent("config.toml") }

    /// Which state each event reports, in the words `AgentTabState` reads.
    ///
    /// `SessionStart` reports identity rather than activity, so it passes no
    /// state and leaves the first line empty — a tab that has an agent in it
    /// but is doing nothing draws no indicator, and the line still carries the
    /// `agent=` and `session=` metadata underneath.
    ///
    /// Every name here is from Kimi's own documented event list. A name it
    /// does not know is not an error it reports: the hook simply never fires,
    /// which is a hook that silently does nothing.
    static let eventStates: [(event: String, state: String)] = [
        ("SessionStart", ""),
        ("UserPromptSubmit", "working"),
        ("PreToolUse", "working"),
        ("PostToolUse", "working"),
        ("PermissionRequest", "awaiting"),
        ("Stop", "done"),
        ("SessionEnd", "ended"),
    ]

    static func command(for state: String) -> String {
        command(for: state, scriptPath: scriptURL.path)
    }

    static func command(for state: String, scriptPath: String) -> String {
        TabStateScript.commandLine(
            scriptPath: scriptPath,
            arguments: TabStateScript.arguments(
                agent: AgentRegistry.kimi.id,
                state: state,
                options: TabStateScript.options(of: AgentRegistry.kimi)))
    }

    /// One `[[hooks]]` block per event.
    ///
    /// No `matcher`: it filters by tool name, and every event here is wanted
    /// for every tool. `timeout` is set low on purpose — this script writes one
    /// small file, and a hook that hangs holds up the agent's turn.
    static var block: String {
        block(scriptPath: scriptURL.path)
    }

    static func block(scriptPath: String) -> String {
        var lines = [
            "# Phantom: reports this tab's agent state to the sidebar.",
            "# Managed by Phantom. Edit the app's Settings rather than these blocks.",
        ]
        for (event, state) in eventStates {
            lines += [
                "",
                "[[hooks]]",
                "event = \"\(event)\"",
                "command = \(tomlString(command(for: state, scriptPath: scriptPath)))",
                "timeout = 5",
            ]
        }
        return lines.joined(separator: "\n")
    }

    static func installed(into text: String, scriptPath: String) -> String {
        let cleaned = removed(from: text)
        let separator = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "\n\n"
        return cleaned + separator + block(scriptPath: scriptPath) + "\n"
    }

    /// A TOML basic string. The path is the reader's home directory and can
    /// hold a backslash or a quote, and either one unescaped makes the whole
    /// file unparseable — which takes down their model and permissions
    /// settings, not just this hook.
    static func tomlString(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    static let scriptBody = TabStateScript.body

    static private(set) var lastError: String?

    // MARK: Reading what is there

    /// Whether a `[[hooks]]` block belongs to Phantom, decided only by the
    /// script it runs.
    static func isPhantomBlock(_ lines: [String]) -> Bool {
        lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("command") else { return false }
            return trimmed.contains(scriptName)
        }
    }

    /// The text with every Phantom block removed, and everything else — the
    /// reader's own hooks, their comments, their blank lines — kept as written.
    static func removed(from text: String) -> String {
        var kept: [String] = []
        var block: [String] = []
        var inBlock = false

        func flush() {
            if !isPhantomBlock(block) { kept += block }
            block = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[[hooks]]" {
                flush()
                inBlock = true
                block = [line]
                continue
            }
            /// Any other table header ends the array-of-tables block.
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                flush()
                inBlock = false
                kept.append(line)
                continue
            }
            if inBlock { block.append(line) } else { kept.append(line) }
        }
        flush()

        /// The comment lines this installer writes above its blocks sit outside
        /// them, so they are dropped by name rather than by structure.
        kept = kept.filter { !$0.hasPrefix("# Phantom: reports this tab's agent state") }
        kept = kept.filter { !$0.hasPrefix("# Managed by Phantom. Edit the app's Settings") }

        return kept.joined(separator: "\n")
    }

    static func isRegistered(in text: String) -> Bool {
        var block: [String] = []
        var inBlock = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[[hooks]]" {
                if isPhantomBlock(block) { return true }
                inBlock = true
                block = []
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if isPhantomBlock(block) { return true }
                inBlock = false
                block = []
                continue
            }
            if inBlock { block.append(line) }
        }
        return isPhantomBlock(block)
    }

    /// Whether what is installed is what this build ships — both halves, since
    /// a stale script is invisible to a check that only reads the config.
    ///
    /// Two ways to go stale. The script's own text changes when Phantom ships
    /// a new one, and the *path* in the config changes when the reader moves
    /// the app or sets `KIMI_CODE_HOME` — which leaves entries pointing at a
    /// script that is not there, and a hook that fails silently on every
    /// event.
    static var isStale: Bool {
        guard isInstalled else { return false }
        if isScriptStale { return true }
        guard let text = read(at: configURL) else { return true }
        return !text.contains(scriptURL.path)
    }

    static var isScriptStale: Bool {
        guard let onDisk = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            return true
        }
        return onDisk != scriptBody
    }

    static var isInstalled: Bool {
        guard let text = read(at: configURL) else { return false }
        return isRegistered(in: text)
    }

    // MARK: Writing

    static func install() -> Bool {
        lastError = nil
        do {
            try FileManager.default.createDirectory(
                at: kimiDir, withIntermediateDirectories: true)
            try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return fail("could not write \(scriptURL.path)", error)
        }

        let existing = read(at: configURL) ?? ""
        return write(installed(into: existing, scriptPath: scriptURL.path), to: configURL)
    }

    static func uninstall() -> Bool {
        lastError = nil
        guard let text = read(at: configURL) else { return true }
        let cleaned = removed(from: text)
        guard write(cleaned, to: configURL) else { return false }
        try? FileManager.default.removeItem(at: scriptURL)
        return true
    }

    /// Brings an existing installation up to this build, and installs nothing.
    /// An agent with no hook is an agent the reader never asked about.
    static func repairIfStale() -> Bool {
        guard isInstalled, isStale else { return false }
        return install()
    }

    // MARK: Files

    static func read(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private static func write(_ text: String, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return fail("could not write \(url.path)", error)
        }
    }

    private static func fail(_ message: String, _ error: Error? = nil) -> Bool {
        lastError = error.map { "\(message): \($0.localizedDescription)" } ?? message
        return false
    }
}
