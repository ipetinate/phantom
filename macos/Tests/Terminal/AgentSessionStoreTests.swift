import Foundation
@testable import Ghostty
import SQLite3
import Testing

/// Recovering a session id from the store the agent keeps for itself, for the
/// tab whose hook never got to report one.
///
/// The gap these cover: a tab where an agent was opened and nothing has been
/// asked of it yet. No hook has fired, so the tab-state file names the agent
/// and no session, and the restore falls back to "whatever is newest in this
/// directory" — which is how a restored tab ends up in a conversation that
/// belonged to some other tab, or to some other project entirely.
///
/// Everything here runs against a directory tree the test builds, never the
/// developer's own `~/.claude` or `~/.codex`: the point is to pin the reading,
/// and a fixture that changes whenever somebody starts an agent pins nothing.
struct AgentSessionStoreTests {
    private let sessionID = "01a000ad-ca19-7f11-8735-369a1e288b70"
    private let otherSessionID = "01a00090-b0b0-7a52-9698-fa5adf53e115"

    // MARK: - Fixture

    private func withTemporaryTree(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("phantom-agent-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func store(in root: URL) -> AgentSessionStore {
        AgentSessionStore(
            claudeProjectsDirectory: root
                .appendingPathComponent("claude", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true),
            codexSessionsDirectory: root
                .appendingPathComponent("codex", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true),
            openCodeDatabase: root.appendingPathComponent("opencode.db")
        )
    }

    private func write(_ contents: String, to url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path
            )
        }
    }

    /// A rollout shaped like the ones Codex writes: a `session_meta` record on
    /// the first line, carrying the id and the directory the session started
    /// in, followed by a transcript this never reads.
    private func writeCodexRollout(
        in root: URL,
        day: String = "2026/08/14",
        name: String,
        cwd: String,
        sessionID: String,
        modified: Date,
        padding: Int = 0
    ) throws {
        let filler = String(repeating: "instruction text. ", count: padding)
        let meta = """
        {"timestamp":"2026-08-14T14:29:44.767Z","type":"session_meta","payload":\
        {"filler":"\(filler)","session_id":"\(sessionID)","id":"\(sessionID)",\
        "cwd":"\(cwd)","originator":"codex_exec","cli_version":"0.147.0"}}
        {"timestamp":"2026-08-14T14:29:45.100Z","type":"event_msg","payload":{}}
        """

        let url = store(in: root).codexSessionsDirectory
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent("rollout-2026-08-14T11-29-44-\(name).jsonl")
        try write(meta, to: url, modified: modified)
    }

    /// A Claude Code session file: the folder is named after the working
    /// directory, the file after the session id, and the contents are never
    /// opened.
    private func writeClaudeSession(
        in root: URL, folder: String, sessionID: String, modified: Date
    ) throws {
        let url = store(in: root).claudeProjectsDirectory
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        try write("{\"type\":\"mode\"}\n", to: url, modified: modified)
    }

    private struct OpenCodeRow {
        let id: String
        let directory: String
        let updated: Int
        var parent: String?
        var archived: Int?
    }

    private func writeOpenCodeDatabase(in root: URL, rows: [OpenCodeRow]) throws {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(
            store(in: root).openCodeDatabase.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        try #require(opened == SQLITE_OK)
        let handle = try #require(database)
        defer { sqlite3_close(handle) }

        var statements = ["""
        CREATE TABLE session (
          id TEXT PRIMARY KEY,
          directory TEXT NOT NULL,
          parent_id TEXT,
          time_archived INTEGER,
          time_updated INTEGER NOT NULL
        );
        """]

        for row in rows {
            let parent = row.parent.map { "'\(Self.quoted($0))'" } ?? "NULL"
            let archived = row.archived.map(String.init) ?? "NULL"
            statements.append("""
            INSERT INTO session (id, directory, parent_id, time_archived, time_updated)
            VALUES ('\(Self.quoted(row.id))', '\(Self.quoted(row.directory))', \
            \(parent), \(archived), \(row.updated));
            """)
        }

        for sql in statements {
            try #require(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
    }

    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - Codex

    @Test func codexFindsTheSessionThatWasStartedInThisDirectory() throws {
        try withTemporaryTree { root in
            let wanted = root.appendingPathComponent("wanted", isDirectory: true).path
            let other = root.appendingPathComponent("other", isDirectory: true).path

            try writeCodexRollout(
                in: root, name: otherSessionID, cwd: other,
                sessionID: otherSessionID, modified: Date(timeIntervalSince1970: 2_000)
            )
            try writeCodexRollout(
                in: root, name: sessionID, cwd: wanted,
                sessionID: sessionID, modified: Date(timeIntervalSince1970: 1_000)
            )

            #expect(store(in: root).mostRecentSessionID(
                agent: .codex, workingDirectory: wanted
            ) == sessionID)
        }
    }

    /// The point of the whole exercise: the newest session overall is not the
    /// answer, because that is what `codex resume --last` already gives and
    /// what puts a restored tab in somebody else's conversation.
    @Test func aSessionFromAnotherDirectoryIsNotBorrowed() throws {
        try withTemporaryTree { root in
            try writeCodexRollout(
                in: root, name: otherSessionID,
                cwd: root.appendingPathComponent("elsewhere", isDirectory: true).path,
                sessionID: otherSessionID, modified: Date(timeIntervalSince1970: 9_000)
            )

            #expect(store(in: root).mostRecentSessionID(
                agent: .codex,
                workingDirectory: root.appendingPathComponent("here", isDirectory: true).path
            ) == nil)
        }
    }

    /// Two sessions in the same directory: the most recently touched one wins,
    /// which is the same session `--last` would have picked *within* the
    /// directory, and the only sensible answer when nothing on disk says which
    /// of two tabs a session belonged to.
    @Test func theMostRecentlyTouchedSessionForTheDirectoryWins() throws {
        try withTemporaryTree { root in
            let directory = root.appendingPathComponent("project", isDirectory: true).path

            try writeCodexRollout(
                in: root, day: "2026/08/12", name: otherSessionID, cwd: directory,
                sessionID: otherSessionID, modified: Date(timeIntervalSince1970: 1_000)
            )
            try writeCodexRollout(
                in: root, day: "2026/08/14", name: sessionID, cwd: directory,
                sessionID: sessionID, modified: Date(timeIntervalSince1970: 5_000)
            )

            #expect(store(in: root).mostRecentSessionID(
                agent: .codex, workingDirectory: directory
            ) == sessionID)
        }
    }

    /// A session started in an older partition but used since is still the
    /// newest one, so the day folders cannot be read as an ordering on
    /// recency — only as a bound on how far back to look.
    @Test func anOldPartitionCanStillHoldTheNewestSession() throws {
        try withTemporaryTree { root in
            let directory = root.appendingPathComponent("project", isDirectory: true).path

            try writeCodexRollout(
                in: root, day: "2026/08/09", name: sessionID, cwd: directory,
                sessionID: sessionID, modified: Date(timeIntervalSince1970: 8_000)
            )
            try writeCodexRollout(
                in: root, day: "2026/08/14", name: otherSessionID, cwd: directory,
                sessionID: otherSessionID, modified: Date(timeIntervalSince1970: 2_000)
            )

            #expect(store(in: root).mostRecentSessionID(
                agent: .codex, workingDirectory: directory
            ) == sessionID)
        }
    }

    /// `/a/src` is not `/a/src2`. Matching directories by prefix would hand a
    /// tab its neighbor's conversation, which is the bug this whole lookup
    /// exists to stop rather than to reintroduce.
    @Test func aSiblingDirectorySharingAPrefixIsNotAMatch() throws {
        try withTemporaryTree { root in
            let sibling = root.appendingPathComponent("src2", isDirectory: true).path
            try writeCodexRollout(
                in: root, name: sessionID, cwd: sibling,
                sessionID: sessionID, modified: Date(timeIntervalSince1970: 1_000)
            )

            #expect(store(in: root).mostRecentSessionID(
                agent: .codex,
                workingDirectory: root.appendingPathComponent("src", isDirectory: true).path
            ) == nil)
        }
    }

    /// A tab opened through a symlink and an agent recording the path it
    /// resolved to are the same directory — `/tmp` and `/private/tmp` being
    /// the case that turns up on every Mac.
    @Test func aSymlinkedWorkingDirectoryStillMatches() throws {
        try withTemporaryTree { root in
            let real = root.appendingPathComponent("real", isDirectory: true)
            let link = root.appendingPathComponent("link", isDirectory: true)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

            try writeCodexRollout(
                in: root, name: sessionID, cwd: real.resolvingSymlinksInPath().path,
                sessionID: sessionID, modified: Date(timeIntervalSince1970: 1_000)
            )

            #expect(store(in: root).mostRecentSessionID(
                agent: .codex, workingDirectory: link.path
            ) == sessionID)
        }
    }

    /// The metadata is read from a bounded prefix, so a record that does not
    /// begin with it is skipped rather than chased through a transcript that
    /// grows without limit. Documented here because it is a real edge of the
    /// implementation, and skipping is the safe half of it.
    @Test func metadataPastTheReadBoundIsNotFound() throws {
        try withTemporaryTree { root in
            let directory = root.appendingPathComponent("project", isDirectory: true).path
            try writeCodexRollout(
                in: root, name: sessionID, cwd: directory,
                sessionID: sessionID, modified: Date(timeIntervalSince1970: 1_000),
                padding: 1_000
            )

            #expect(store(in: root).mostRecentSessionID(
                agent: .codex, workingDirectory: directory
            ) == nil)
        }
    }

    @Test func anEmptyStoreYieldsNoID() throws {
        try withTemporaryTree { root in
            for agent in [CodingAgent.claude, .codex, .opencode] {
                #expect(store(in: root).mostRecentSessionID(
                    agent: agent, workingDirectory: root.path
                ) == nil, "\(agent.rawValue) invented an id")
            }
        }
    }

    // MARK: - Claude Code

    @Test func claudeTakesTheNewestSessionInItsProjectFolder() throws {
        try withTemporaryTree { root in
            let directory = "/Users/somebody/Projects/phantom"
            let folder = "-Users-somebody-Projects-phantom"

            try writeClaudeSession(
                in: root, folder: folder, sessionID: otherSessionID,
                modified: Date(timeIntervalSince1970: 1_000)
            )
            try writeClaudeSession(
                in: root, folder: folder, sessionID: sessionID,
                modified: Date(timeIntervalSince1970: 4_000)
            )
            try writeClaudeSession(
                in: root, folder: "-Users-somebody-Projects-other",
                sessionID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                modified: Date(timeIntervalSince1970: 9_000)
            )

            #expect(store(in: root).mostRecentSessionID(
                agent: .claude, workingDirectory: directory
            ) == sessionID)
        }
    }

    /// A dotted path directory flattens the dot along with the separators,
    /// which is the shape `~/.config/...` sessions land under.
    @Test func aDottedPathFlattensIntoOneFolderName() throws {
        try withTemporaryTree { root in
            try writeClaudeSession(
                in: root, folder: "-Users-somebody--config-zed-themes",
                sessionID: sessionID, modified: Date(timeIntervalSince1970: 1_000)
            )

            #expect(store(in: root).mostRecentSessionID(
                agent: .claude, workingDirectory: "/Users/somebody/.config/zed-themes"
            ) == sessionID)
        }
    }

    /// The flattening rule is Claude Code's and is not published, and the
    /// observable folder names are consistent with two readings of it. Both are
    /// tried, so a path holding a character the two disagree about — an
    /// underscore — is found either way.
    @Test func bothFlatteningsOfAnUnderscorePathAreTried() throws {
        #expect(AgentSessionStore.claudeProjectNames(for: "/Users/a/my_repo")
            == ["-Users-a-my-repo", "-Users-a-my_repo"])
        #expect(AgentSessionStore.claudeProjectNames(for: "/Users/a/repo")
            == ["-Users-a-repo"])
    }

    @Test func claudeSessionsUnderAnUnderscoreFolderAreFound() throws {
        try withTemporaryTree { root in
            try writeClaudeSession(
                in: root, folder: "-Users-somebody-my_repo",
                sessionID: sessionID, modified: Date(timeIntervalSince1970: 1_000)
            )

            #expect(store(in: root).mostRecentSessionID(
                agent: .claude, workingDirectory: "/Users/somebody/my_repo"
            ) == sessionID)
        }
    }

    /// The file name becomes a shell argument, so it goes through the same
    /// sanitizer the tab-state file's ids do — a name that could be read as a
    /// flag is not an id.
    @Test func aFileNameThatCouldBeAFlagIsNotTakenAsAnID() throws {
        try withTemporaryTree { root in
            try writeClaudeSession(
                in: root, folder: "-Users-somebody-repo",
                sessionID: "--dangerously-skip-permissions",
                modified: Date(timeIntervalSince1970: 9_000)
            )
            try writeClaudeSession(
                in: root, folder: "-Users-somebody-repo", sessionID: sessionID,
                modified: Date(timeIntervalSince1970: 1_000)
            )

            #expect(store(in: root).mostRecentSessionID(
                agent: .claude, workingDirectory: "/Users/somebody/repo"
            ) == sessionID)
        }
    }

    // MARK: - OpenCode

    @Test func openCodeQueriesItsDatabaseByDirectory() throws {
        try withTemporaryTree { root in
            let directory = "/Users/somebody/Projects/phantom"
            try writeOpenCodeDatabase(in: root, rows: [
                OpenCodeRow(
                    id: "ses_fff7d5524ffeUDAwYb4uQBCvuy",
                    directory: "/Users/somebody/Projects/other", updated: 9_000
                ),
                OpenCodeRow(
                    id: "ses_fff4fad66ffew9XwYrbmxeGqEb",
                    directory: directory, updated: 5_000
                ),
                OpenCodeRow(
                    id: "ses_fff6dc11bffe11AQiSz5SRq3eJ",
                    directory: directory, updated: 1_000
                )
            ])

            #expect(store(in: root).mostRecentSessionID(
                agent: .opencode, workingDirectory: directory
            ) == "ses_fff4fad66ffew9XwYrbmxeGqEb")
        }
    }

    /// A child row is a subagent's thread inside a session, and an archived
    /// one is a session the user has put away. Resuming by either id reopens
    /// something other than the conversation the tab was holding.
    @Test func openCodeSkipsChildAndArchivedSessions() throws {
        try withTemporaryTree { root in
            let directory = "/Users/somebody/Projects/phantom"
            try writeOpenCodeDatabase(in: root, rows: [
                OpenCodeRow(
                    id: "ses_child", directory: directory, updated: 9_000,
                    parent: "ses_fff4fad66ffew9XwYrbmxeGqEb"
                ),
                OpenCodeRow(
                    id: "ses_archived", directory: directory, updated: 8_000,
                    archived: 7_000
                ),
                OpenCodeRow(
                    id: "ses_fff4fad66ffew9XwYrbmxeGqEb",
                    directory: directory, updated: 5_000
                )
            ])

            #expect(store(in: root).mostRecentSessionID(
                agent: .opencode, workingDirectory: directory
            ) == "ses_fff4fad66ffew9XwYrbmxeGqEb")
        }
    }

    /// A database from a version that kept sessions somewhere else reads as no
    /// answer, not as a crash: every failure here has the same meaning, and
    /// the caller already knows what to do without an id.
    @Test func aDatabaseWithNoSessionTableYieldsNoID() throws {
        try withTemporaryTree { root in
            try write("not a database at all", to: store(in: root).openCodeDatabase)

            #expect(store(in: root).mostRecentSessionID(
                agent: .opencode, workingDirectory: "/Users/somebody/Projects/phantom"
            ) == nil)
        }
    }

    // MARK: - Reading a field out of a JSON prefix

    @Test func aStringFieldIsReadOutOfAJSONFragment() {
        #expect(AgentSessionStore.jsonStringValue(
            forKey: "cwd", in: #"{"a":1,"cwd":"/tmp/x","b":2}"#) == "/tmp/x")
        #expect(AgentSessionStore.jsonStringValue(
            forKey: "cwd", in: #"{"cwd" : "/tmp/x"}"#) == "/tmp/x")
        #expect(AgentSessionStore.jsonStringValue(
            forKey: "cwd", in: #"{"other":"/tmp/x"}"#) == nil)
    }

    /// The fragment is a prefix of a much longer line, so a value the cut ran
    /// through is reported as absent — a half-read path that happened to match
    /// a real directory would resume the wrong session with confidence.
    @Test func aValueTheReadBoundCutThroughIsNotReturned() {
        #expect(AgentSessionStore.jsonStringValue(
            forKey: "cwd", in: #"{"cwd":"/Users/somebody/Proj"#) == nil)
    }

    @Test func anEscapedCharacterInAValueSurvives() {
        #expect(AgentSessionStore.jsonStringValue(
            forKey: "cwd", in: #"{"cwd":"/tmp/say \"hi\""}"#) == #"/tmp/say "hi""#)
        #expect(AgentSessionStore.jsonStringValue(
            forKey: "cwd", in: #"{"cwd":"\/tmp\/x"}"#) == "/tmp/x")
    }

    /// A key that appears before the one being looked for, and whose value is
    /// not a string, does not derail the scan.
    @Test func aNonStringValueForTheKeyIsSkippedAndTheScanContinues() {
        #expect(AgentSessionStore.jsonStringValue(
            forKey: "cwd", in: #"{"cwd":null,"payload":{"cwd":"/tmp/x"}}"#) == "/tmp/x")
    }

    // MARK: - Comparing directories

    @Test func aTrailingSeparatorIsNotADifferentDirectory() {
        #expect(AgentSessionStore.directory("/tmp/x/", isOneOf: ["/tmp/x"]))
        #expect(AgentSessionStore.directory("/tmp/x", isOneOf: ["/tmp/x"]))
        #expect(!AgentSessionStore.directory("/tmp/x2", isOneOf: ["/tmp/x"]))
        #expect(!AgentSessionStore.directory("/tmp", isOneOf: ["/tmp/x"]))
    }

    @Test func anEmptyWorkingDirectoryHasNothingToCompare() {
        #expect(AgentSessionStore.comparablePaths(for: "").isEmpty)
    }
}
