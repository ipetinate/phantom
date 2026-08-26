import Foundation

/// Registers Phantom's MCP server with Codex.
///
/// **Codex is the one agent whose configuration is not JSON.** Its servers live
/// in `~/.codex/config.toml`, in a table named `mcp_servers` — snake_case, not
/// the `mcpServers` the other three use — beside the reader's model, approval
/// policy and sandbox settings. OpenAI's documentation gives both: "Codex
/// stores MCP configuration in `config.toml` alongside other Codex
/// configuration settings. By default this is `~/.codex/config.toml`", and the
/// worked example is a `[mcp_servers.<name>]` table with `command` and `args`.
/// <https://learn.chatgpt.com/docs/extend/mcp?surface=cli> and
/// <https://learn.chatgpt.com/docs/config-file/config-reference>
///
/// **This edits TOML as text, and that is a decision rather than a shortcut.**
/// There is no TOML parser in this app and adding one to write four lines would
/// be a dependency in the signing pipeline for the rest of the project's life.
/// What makes text safe here is the same thing that makes
/// `AntigravityHooksInstaller` safe: Phantom owns exactly one table and rewrites
/// it whole. Everything outside `[mcp_servers.phantom]` is copied through
/// untouched, byte for byte, comments and ordering included — which a
/// parse-and-reserialize would not have managed.
///
/// **What it refuses to do.** A table can be spelled more than one way in TOML,
/// and only one of those spellings this can own. If the file already declares
/// `mcp_servers` as a bare table — `[mcp_servers]` with the servers as keys
/// inside it — or assigns it at the top level, then appending
/// `[mcp_servers.phantom]` would define the same key twice and Codex would
/// refuse to parse the whole file. So that case is detected and the write is
/// refused with a message naming it. A reader who has to add four lines by hand
/// is in a much better position than one whose Codex stopped starting.
@MainActor
enum CodexMCPInstaller {
    /// The table Phantom owns, in full.
    static var table: String { "mcp_servers.\(MCPServerCommand.name)" }

    /// The same home `CodexHooksInstaller` resolves — `CODEX_HOME`, then
    /// `~/.codex-cli` if it exists, then `~/.codex`. One resolver, for the
    /// reason that file gives: two of them is one too many.
    static var configURL: URL {
        CodexHooksInstaller.codexDir.appendingPathComponent("config.toml")
    }

    static private(set) var lastError: String?

    // MARK: The block

    /// The four lines Phantom writes, and the whole of what it owns.
    static func block(executable: String) -> String {
        let args = MCPServerCommand.arguments
            .map { "\"\(escaped($0))\"" }
            .joined(separator: ", ")

        return """
        [\(table)]
        command = "\(escaped(executable))"
        args = [\(args)]
        """
    }

    static var block: String? {
        MCPServerCommand.executablePath.map(block(executable:))
    }

    /// A TOML basic string takes exactly two characters badly, and a bundle
    /// path can hold both: a reader may put an app in a directory with a quote
    /// or a backslash in its name. Everything else in a path is literal.
    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Reading the file as lines

    /// The table path a line declares, or nil when the line declares none.
    ///
    /// `[[…]]` is an array of tables and is deliberately not one: Phantom's
    /// table is never an array, and treating one as a header would let the
    /// removal below swallow somebody else's entries.
    static func header(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.hasPrefix("[[")
        else { return nil }
        return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// The parts of a table path, with the quotes TOML allows around each one
    /// taken off.
    static func parts(of path: String) -> [String] {
        path.split(separator: ".", omittingEmptySubsequences: false).map { part in
            let trimmed = String(part).trimmingCharacters(in: .whitespaces)
            for quote in ["\"", "'"] where trimmed.hasPrefix(quote) && trimmed.hasSuffix(quote)
                && trimmed.count >= 2 {
                return String(trimmed.dropFirst().dropLast())
            }
            return trimmed
        }
    }

    /// Whether a table path is Phantom's, including its sub-tables. An `env`
    /// table under Phantom's server belongs to Phantom and goes with it.
    static func isPhantom(_ path: String) -> Bool {
        let parts = parts(of: path)
        guard parts.count >= 2 else { return false }
        return parts[0] == "mcp_servers" && parts[1] == MCPServerCommand.name
    }

    /// Whether the file already spells `mcp_servers` in a way this cannot own.
    ///
    /// Two shapes: a bare `[mcp_servers]` table, whose servers are keys inside
    /// it, and a top-level `mcp_servers = { … }`. Appending
    /// `[mcp_servers.phantom]` on top of either defines the key twice, which
    /// makes the file unparseable rather than merely wrong.
    ///
    /// The top-level assignment is looked for only above the first table
    /// header, because a bare key after a header belongs to that header's
    /// table: an `mcp_servers = …` inside `[foo]` is `foo.mcp_servers` and
    /// collides with nothing.
    static func hasUnownableTable(in text: String) -> Bool {
        var seenHeader = false

        for line in text.components(separatedBy: .newlines) {
            if let path = header(of: line) {
                seenHeader = true
                if parts(of: path) == ["mcp_servers"] { return true }
                continue
            }

            guard !seenHeader else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("mcp_servers") else { continue }
            let rest = trimmed.dropFirst("mcp_servers".count).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("=") { return true }
        }

        return false
    }

    // MARK: Merging

    /// Everything Phantom owns, as it currently stands in the file.
    ///
    /// A block runs from its header to the next header or the end. Returned
    /// trimmed, so it can be compared against `block` without the surrounding
    /// blank lines mattering.
    static func phantomBlock(in text: String) -> String? {
        var kept: [String] = []
        var inside = false

        for line in text.components(separatedBy: .newlines) {
            if let path = header(of: line) {
                inside = isPhantom(path)
            }
            if inside { kept.append(line) }
        }

        guard !kept.isEmpty else { return nil }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isRegistered(in text: String) -> Bool {
        phantomBlock(in: text) != nil
    }

    /// True when Phantom's table is there but is not the one this build writes
    /// — almost always because the bundle moved and the `command` in it no
    /// longer resolves.
    static func isStale(in text: String) -> Bool {
        guard let found = phantomBlock(in: text), let block else { return false }
        return found != block.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything that is not Phantom's, in the order it was written.
    static func removed(from text: String) -> String {
        var kept: [String] = []
        var inside = false

        for line in text.components(separatedBy: .newlines) {
            if let path = header(of: line) {
                inside = isPhantom(path)
            }
            if !inside { kept.append(line) }
        }

        return kept.joined(separator: "\n")
    }

    /// The file with Phantom's table replaced, or nil when it cannot be owned.
    ///
    /// Appended at the end, which is always valid: a table header ends the
    /// previous table, so nothing that was a top-level key becomes one of
    /// Phantom's.
    static func merged(_ block: String, into text: String) -> String? {
        guard !hasUnownableTable(in: text) else { return nil }

        let rest = removed(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return block + "\n" }
        return rest + "\n\n" + block + "\n"
    }

    // MARK: Disk

    /// Nil when a file is there and cannot be read as UTF-8, empty when there
    /// is no file — the same distinction `MCPConfigFile.read` draws, and for
    /// the same reason.
    static func read(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? nil : ""
        }
        return String(data: data, encoding: .utf8)
    }

    /// Temp file, then rename — which is what `atomically` does. A truncated
    /// `config.toml` is a Codex that will not start.
    private static func write(_ text: String, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    static var isRegistered: Bool {
        read(at: configURL).map(isRegistered(in:)) ?? false
    }

    @discardableResult
    static func register() -> Bool {
        guard let block else { return fail("Phantom could not find its own executable") }
        guard let before = read(at: configURL) else {
            return fail("config.toml is not readable as text")
        }
        guard let after = merged(block, into: before) else {
            return fail("config.toml already declares mcp_servers in a shape Phantom can't merge into \u{2014} add [\(table)] by hand")
        }
        guard write(after, to: configURL) else { return fail("writing config.toml") }
        guard let reread = read(at: configURL), isRegistered(in: reread) else {
            return fail("config.toml was written but the server is not registered")
        }

        lastError = nil
        return true
    }

    @discardableResult
    static func remove() -> Bool {
        guard let before = read(at: configURL) else {
            return fail("config.toml is not readable as text")
        }

        let after = removed(from: before).trimmingCharacters(in: .whitespacesAndNewlines)
        guard write(after.isEmpty ? "" : after + "\n", to: configURL) else {
            return fail("writing config.toml")
        }
        guard let reread = read(at: configURL), !isRegistered(in: reread) else {
            return fail("config.toml was written but the server is still registered")
        }

        lastError = nil
        return true
    }

    @discardableResult
    static func repairIfStale() -> Bool {
        guard let text = read(at: configURL), isRegistered(in: text), isStale(in: text)
        else { return false }
        return register()
    }

    private static func fail(_ message: String) -> Bool {
        lastError = message
        return false
    }
}
