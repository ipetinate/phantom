import Foundation
import SQLite3

/// The session each coding-agent CLI keeps for itself on disk, read back as
/// the id a hook never got to report.
///
/// A hook script learns the session id from the payload its agent hands it,
/// and none of the three integrations here registers for a session-*start*
/// event: the installers wire up prompt, tool, stop and end events, all of
/// which need the user to have said something first. So a tab where an agent
/// was opened but nothing has been asked of it yet holds no id at all, and its
/// restore falls back to "the newest conversation in this directory"
/// (`codex resume --last`, `claude --continue`, `opencode --continue`). That
/// fallback is how a restored tab lands in a conversation that belonged to a
/// different tab.
///
/// Registering for a start event would close part of the gap and is worth
/// doing, but not all of it: it only helps once the user reinstalls the hooks,
/// and only if that event's payload names the session — neither of which this
/// can wait on to know which conversation a tab was holding.
///
/// Each CLI does write its session down before the first prompt, though, and
/// records the directory it was started in. That answers the question the
/// fallback was guessing at: which session belongs to *this* directory. It is
/// still a guess between two tabs open on the same directory — nothing on
/// disk tells those apart — but it can no longer cross into an unrelated
/// project, which is the failure that actually hurt.
///
/// Nothing here is authoritative. An id in the tab-state file always wins,
/// because that one was reported by the conversation that was in the tab.
/// This is the floor under it, not a replacement for it.
///
/// The roots are stored rather than computed so a test can point them at a
/// directory tree it built itself, instead of at whatever the developer's own
/// agents happen to have left in `$HOME`.
struct AgentSessionStore: Sendable {
    /// `~/.claude/projects`, holding one directory per working directory.
    let claudeProjectsDirectory: URL

    /// `~/.codex/sessions`, holding `<year>/<month>/<day>` partitions.
    let codexSessionsDirectory: URL

    /// `~/.local/share/opencode/opencode.db`, holding a `session` table.
    let openCodeDatabase: URL

    /// How many `<year>/<month>/<day>` partitions of Codex sessions to look
    /// through, newest first. A session started before this window and used
    /// since still lives in the partition it was created in, so the bound is
    /// on how far back a *creation* date may be — a week and a day of them.
    private static let maxDayDirectories = 8

    /// How many session files to consider from any one directory. A directory
    /// listing is cheap and pre-fetches the timestamps it is sorted by; this
    /// only exists so that a home directory with years of sessions in one
    /// folder cannot turn a restore into a sort of ten thousand entries.
    private static let maxFilesPerDirectory = 256

    /// How many Codex rollouts to actually open. The working directory is
    /// inside the file rather than in its name, so each candidate costs a
    /// read — which is the one thing here worth being stingy about.
    private static let maxSessionFileReads = 24

    /// How much of a session file to read. Codex writes its `session_meta`
    /// record first and puts the working directory around 200 bytes into it, so
    /// this is roughly forty times what a real rollout needs — and a record that
    /// still does not fit is skipped rather than chased through a transcript.
    private static let metadataPrefixBytes = 8 * 1024

    /// How many of OpenCode's session rows to look through, newest first. The
    /// directory cannot be matched inside the query — see `openCodeSessionID`
    /// — so this is the bound on rows read back and normalized here instead.
    private static let maxOpenCodeRows = 512

    /// How long to wait for another process's write lock before giving up on
    /// the OpenCode database. Short on purpose: a restore that cannot read
    /// the store falls back to the imprecise resume, and a restore that
    /// blocks does not finish at all.
    private static let sqliteBusyTimeoutMilliseconds: Int32 = 250

    /// Where each agent keeps its sessions on this machine, honoring the same
    /// environment overrides the CLIs themselves do.
    static let `default` = AgentSessionStore(
        claudeProjectsDirectory: defaultClaudeDirectory
            .appendingPathComponent("projects", isDirectory: true),
        codexSessionsDirectory: CodexHooksInstaller.codexDir
            .appendingPathComponent("sessions", isDirectory: true),
        openCodeDatabase: defaultOpenCodeDataDirectory
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db")
    )

    private static var defaultClaudeDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    private static var defaultOpenCodeDataDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["XDG_DATA_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
    }

    /// The most recent session `agent` recorded for `workingDirectory`, or nil
    /// when its store holds none, cannot be read, or is not there at all.
    ///
    /// Blocking, and deliberately not isolated to the main actor: every path
    /// through it is filesystem or SQLite work. Callers get off the main
    /// thread first — a restore that stalls the window server to look at a
    /// database is worse than a restore that resumes imprecisely.
    func mostRecentSessionID(agent: CodingAgent, workingDirectory: String) -> String? {
        let directories = Self.comparablePaths(for: workingDirectory)
        guard !directories.isEmpty else { return nil }

        switch agent {
        case .claude: return claudeSessionID(for: directories)
        case .codex: return codexSessionID(for: directories)
        case .opencode: return openCodeSessionID(for: directories)

        /// Antigravity keeps a store too — `agy --continue` is documented as
        /// finding the last conversation for the current workspace "by
        /// consulting a local cache file" — but neither that file's path nor
        /// its format is documented anywhere, and guessing at either would
        /// mean reading an id out of a file whose meaning is assumed. An id
        /// resumed into the wrong conversation is worse than no id: the
        /// fallback for nil is `agy --continue`, which asks Antigravity to
        /// consult that same cache itself, with the workspace scoping this
        /// method exists to reconstruct already built in.
        case .antigravity: return nil

        /// Kimi and Pi both keep sessions, and neither documents where. The
        /// same reasoning as Antigravity above applies, and the fallback is
        /// better for them than it is for it: `kimi --continue` is documented
        /// as resuming the most recent session *for the current working
        /// directory*, which is exactly the scoping this method reconstructs
        /// by hand for the others.
        ///
        /// Pi is the weaker of the two. Its `--continue` is documented as
        /// "continue most recent session" with no mention of the directory, so
        /// two tabs on two projects may both land in whichever conversation
        /// was touched last. That is the pre-session-id behaviour every agent
        /// here used to have, it is recoverable by hand, and it beats resuming
        /// an id read out of a file whose format was guessed at.
        case .kimi, .pi: return nil
        }
    }

    // MARK: - Claude Code

    /// Claude Code files every session for a working directory in one folder
    /// named after that directory, and names the file after the session id.
    /// So the id needs no file read at all: the folder is the index, and the
    /// newest `.jsonl` in it is the newest conversation.
    ///
    /// Flattening a path into a folder name loses information — `/a/b.c` and
    /// `/a/b-c` land on the same name — and that lossiness is not corrected
    /// here on purpose. It is the CLI's own: two paths that collide are one
    /// project as far as `claude --continue` is concerned, so a session in
    /// that folder is exactly a session the CLI would have offered. Being
    /// stricter than the tool would reject sessions the tool accepts.
    private func claudeSessionID(for directories: [String]) -> String? {
        var newestID: String?
        var newestDate = Date.distantPast

        for name in Self.deduplicated(directories.flatMap(Self.claudeProjectNames(for:))) {
            let folder = claudeProjectsDirectory
                .appendingPathComponent(name, isDirectory: true)

            for file in Self.newestFiles(in: folder, pathExtension: "jsonl") {
                guard file.modified > newestDate,
                      let id = AgentTabRecord.sanitized(
                          sessionID: file.url.deletingPathExtension().lastPathComponent
                      )
                else { continue }

                newestID = id
                newestDate = file.modified
            }
        }

        return newestID
    }

    /// The folder names a working directory may have been flattened into.
    ///
    /// Two spellings rather than one because the exact rule is Claude Code's
    /// and not published: the observable names are consistent both with
    /// replacing every non-alphanumeric character and with replacing only the
    /// path separators and dots, and the two differ for a path holding an
    /// underscore or a space. Trying both costs a `stat` and covers either;
    /// guessing one and being wrong silently loses the session.
    static func claudeProjectNames(for directory: String) -> [String] {
        var everyNonAlphanumeric = ""
        var separatorsOnly = ""

        for scalar in directory.unicodeScalars {
            let character = Character(scalar)
            everyNonAlphanumeric.append(
                Self.asciiAlphanumerics.contains(scalar) ? character : "-"
            )
            separatorsOnly.append(scalar == "/" || scalar == "." ? "-" : character)
        }

        return everyNonAlphanumeric == separatorsOnly
            ? [everyNonAlphanumeric]
            : [everyNonAlphanumeric, separatorsOnly]
    }

    /// ASCII only, matching a JavaScript `[^a-zA-Z0-9]` rather than Foundation's
    /// `CharacterSet.alphanumerics`, which counts accented and non-Latin
    /// letters as alphanumeric and so would leave them in a name the CLI
    /// replaced.
    private static let asciiAlphanumerics = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    )

    // MARK: - Codex

    /// Codex names each rollout after its timestamp *and* its session id, but
    /// the working directory is only inside the file, in the `session_meta`
    /// record it writes first. So candidates are ordered by modification time
    /// — most recently active session first — and opened until one of them
    /// turns out to have been started here.
    ///
    /// The id is taken from that same record rather than from the file name.
    /// Both carry it, and reading it costs nothing extra once the file is
    /// open, but only the record is a documented field: parsing it out of the
    /// name means knowing where the timestamp ends, which is a format detail
    /// nothing promises to keep.
    private func codexSessionID(for directories: [String]) -> String? {
        let candidates = codexDayDirectories()
            .flatMap { Self.newestFiles(in: $0, pathExtension: "jsonl") }
            .sorted { $0.modified > $1.modified }
            .prefix(Self.maxSessionFileReads)

        for file in candidates {
            guard let head = Self.head(of: file.url, bytes: Self.metadataPrefixBytes),
                  let recorded = Self.jsonStringValue(forKey: "cwd", in: head),
                  Self.directory(recorded, isOneOf: directories),
                  let id = Self.jsonStringValue(forKey: "session_id", in: head)
            else { continue }

            return AgentTabRecord.sanitized(sessionID: id)
        }

        return nil
    }

    /// The `<year>/<month>/<day>` partitions under the sessions root, newest
    /// first. The names are zero-padded numbers, so sorting them backwards as
    /// strings sorts them backwards as dates.
    private func codexDayDirectories() -> [URL] {
        var days: [URL] = []

        for year in Self.subdirectories(of: codexSessionsDirectory) {
            for month in Self.subdirectories(of: year) {
                for day in Self.subdirectories(of: month) {
                    days.append(day)
                    if days.count >= Self.maxDayDirectories { return days }
                }
            }
        }

        return days
    }

    // MARK: - OpenCode

    /// OpenCode keeps its sessions in SQLite, one row per session with the
    /// directory it was started in beside it — so unlike the other two this is
    /// a query rather than a walk.
    ///
    /// The directory is matched in Swift rather than in the `WHERE` clause,
    /// which reads like the wrong way round and is not. SQLite compares the
    /// stored text to the text handed to it, and the stored text is whatever
    /// OpenCode's process saw: `/private/tmp` for a tab in `/tmp`. Only
    /// `directory(_:isOneOf:)` normalizes both sides, and it cannot run inside
    /// the query — so the query narrows by everything else it can and the
    /// matching happens over the rows it returns.
    ///
    /// Which is why there is a row bound. It costs a session in a directory
    /// with several hundred newer sessions elsewhere on the machine, and buys
    /// a lookup that cannot grow with the store.
    ///
    /// Opened read-only, and every failure is silent by design: a missing file,
    /// a database from a version with no `session` table, a schema that has
    /// moved on. All of them mean "no id from here", and the caller already
    /// knows what to do without one.
    private func openCodeSessionID(for directories: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: openCodeDatabase.path) else {
            return nil
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            openCodeDatabase.path, &database, SQLITE_OPEN_READONLY, nil
        ) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, Self.sqliteBusyTimeoutMilliseconds)

        // A child row is one thread inside a session — a subagent's — and
        // resuming by its id opens that thread rather than the conversation the
        // tab was holding. An archived one the user has already put away.
        let query = """
        SELECT id, directory FROM session
         WHERE (parent_id IS NULL OR parent_id = '')
           AND (time_archived IS NULL OR time_archived = 0)
         ORDER BY time_updated DESC
         LIMIT \(Self.maxOpenCodeRows)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idColumn = sqlite3_column_text(statement, 0),
                  let directoryColumn = sqlite3_column_text(statement, 1),
                  Self.directory(String(cString: directoryColumn), isOneOf: directories)
            else { continue }

            return AgentTabRecord.sanitized(sessionID: String(cString: idColumn))
        }

        return nil
    }

    // MARK: - Matching a working directory

    /// Every spelling a directory may have been written down as: as given,
    /// standardized, and with its symlinks resolved.
    ///
    /// Three rather than one because each agent records whatever its own
    /// process saw. A tab opened in `/tmp` has Codex writing down
    /// `/private/tmp`; a project reached through a symlink may be recorded
    /// either side of it. Comparing any single spelling as a string finds
    /// nothing, and finding nothing here is silent — it reads as "no session
    /// for this directory" and falls back to the imprecise resume.
    ///
    /// Trailing separators go, so `/a/src` and `/a/src/` are one directory.
    static func comparablePaths(for directory: String) -> [String] {
        let given = trimmedTrailingSeparator(directory)
        guard !given.isEmpty else { return [] }
        let url = URL(fileURLWithPath: given)
        return deduplicated([
            given,
            trimmedTrailingSeparator(url.standardizedFileURL.path),
            trimmedTrailingSeparator(url.resolvingSymlinksInPath().path)
        ].filter { !$0.isEmpty })
    }

    /// Whether a directory read out of a session store is one of the ones being
    /// looked for.
    ///
    /// Both sides get normalized, and that symmetry is the point rather than
    /// belt-and-braces. `standardizedFileURL` quietly strips a leading
    /// `/private`, so `/private/tmp` and `/tmp` both normalize to `/tmp` and
    /// neither normalizes to `/private/tmp` — which is the spelling Codex and
    /// OpenCode actually store. Normalizing only the directory being searched
    /// for therefore misses the stored one every time, in exactly the case
    /// (`/tmp`) most likely to be tried first by hand.
    ///
    /// Ordered cheapest first: a string compare, then a standardization that
    /// touches no disk, and only then a resolve that does. The first two answer
    /// almost every real comparison, which is what keeps this affordable to run
    /// against a few hundred stored rows.
    ///
    /// Equality throughout, never a prefix: `/a/src2` starts with `/a/src` and
    /// is a different project, and a prefix match here would hand a tab its
    /// neighbor's conversation. (`EditorCenter.documentPaths(under:)` carries
    /// the other half of that lesson — where a prefix *is* wanted, it needs the
    /// separator appended to stop at a directory boundary.)
    static func directory(_ recorded: String, isOneOf wanted: [String]) -> Bool {
        let given = trimmedTrailingSeparator(recorded)
        guard !given.isEmpty else { return false }
        if wanted.contains(given) { return true }

        let url = URL(fileURLWithPath: given)
        if wanted.contains(trimmedTrailingSeparator(url.standardizedFileURL.path)) {
            return true
        }
        return wanted.contains(
            trimmedTrailingSeparator(url.resolvingSymlinksInPath().path)
        )
    }

    private static func trimmedTrailingSeparator(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Reading the stores

    /// A file and the timestamp its siblings are ordered against.
    private struct DatedFile {
        let url: URL
        let modified: Date
    }

    /// The most recently modified files of one extension directly inside a
    /// directory. A listing, never a walk: none of these stores nests session
    /// files below the folder that indexes them.
    private static func newestFiles(in directory: URL, pathExtension: String) -> [DatedFile] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        let dated = entries
            .filter { $0.pathExtension == pathExtension }
            .map {
                DatedFile(
                    url: $0,
                    modified: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.modified > $1.modified }

        return Array(dated.prefix(maxFilesPerDirectory))
    }

    /// The subdirectories directly inside a directory, by name, backwards.
    private static func subdirectories(of directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        return entries
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// The first `bytes` of a file, as text.
    ///
    /// A prefix rather than the whole file because a session transcript grows
    /// without bound and the metadata is at the front of it.
    ///
    /// The cut lands in the middle of a character often enough to matter, and
    /// throwing a whole readable prefix away over its last byte would lose the
    /// metadata for no reason — so an incomplete tail is trimmed off instead.
    /// A UTF-8 sequence runs to four bytes, so at most three of them can be
    /// that tail; anything still undecodable after those is genuinely not text
    /// and the file is skipped, which is the safer half of the trade.
    private static func head(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard var data = try? handle.read(upToCount: bytes), !data.isEmpty else {
            return nil
        }

        for _ in 0..<4 {
            if let text = String(bytes: data, encoding: .utf8) { return text }
            guard !data.isEmpty else { return nil }
            data.removeLast()
        }
        return nil
    }

    /// The first string value for `key` in a fragment of JSON text.
    ///
    /// A scanner and not `JSONSerialization` because the input is deliberately
    /// incomplete: Codex's first record is a single line tens of kilobytes
    /// long — most of it the model's instructions — and the fields worth
    /// having sit in the first few hundred bytes of it. Parsing properly means
    /// reading all of it; scanning means reading none of it that we do not
    /// need. A value the cut ran through is reported as absent rather than as
    /// a truncated path that might match something.
    static func jsonStringValue(forKey key: String, in text: String) -> String? {
        let needle = "\"\(key)\""
        var searchFrom = text.startIndex

        while let keyRange = text.range(of: needle, range: searchFrom..<text.endIndex) {
            searchFrom = keyRange.upperBound

            var index = skippingBlanks(in: text, from: keyRange.upperBound)
            guard index < text.endIndex, text[index] == ":" else { continue }
            index = skippingBlanks(in: text, from: text.index(after: index))
            guard index < text.endIndex, text[index] == "\"" else { continue }
            index = text.index(after: index)

            var value = ""
            while index < text.endIndex, text[index] != "\"" {
                // An escape stands for the character after it. Enough for the
                // paths and ids read here — an encoder that escapes the
                // separator writes `\/`, and one that escapes a quote in a
                // directory name writes `\"` — and wrong only for the control
                // escapes no path or session id contains, where the result
                // simply fails to match anything.
                if text[index] == "\\" {
                    let escaped = text.index(after: index)
                    guard escaped < text.endIndex else { return nil }
                    value.append(text[escaped])
                    index = text.index(after: escaped)
                    continue
                }
                value.append(text[index])
                index = text.index(after: index)
            }

            guard index < text.endIndex else { return nil }
            return value
        }

        return nil
    }

    private static func skippingBlanks(
        in text: String, from start: String.Index
    ) -> String.Index {
        var index = start
        while index < text.endIndex, text[index] == " " || text[index] == "\t" {
            index = text.index(after: index)
        }
        return index
    }
}
