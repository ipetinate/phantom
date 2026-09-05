import Foundation

final class AgentRegistry: @unchecked Sendable {
    static let shared = AgentRegistry()

    static let codexHome = ConfigPath(["$CODEX_HOME", "~/.codex-cli", "~/.codex"])
    static let kimiHome = ConfigPath(["$KIMI_CODE_HOME", "~/.kimi-code"])
    static let antigravityHome: ConfigPath = "~/.gemini/config"
    static let openCodeHome: ConfigPath = "~/.config/opencode"
    static let piHome: ConfigPath = "~/.pi/agent"

    static let builtIn: [AgentDescriptor] = [claude, codex, opencode, antigravity, kimi, pi]

    private let lock = NSLock()
    private var extensionAgents: [AgentDescriptor] = []
    private var byID: [String: AgentDescriptor]

    init(extensionAgents: [AgentDescriptor] = []) {
        self.byID = Dictionary(uniqueKeysWithValues: Self.builtIn.map { ($0.id, $0) })
        setExtensionAgents(extensionAgents)
    }

    var all: [AgentDescriptor] {
        lock.withLock { Self.builtIn + extensionAgents }
    }

    func descriptor(for id: String) -> AgentDescriptor? {
        lock.withLock { byID[id] }
    }

    func setExtensionAgents(_ descriptors: [AgentDescriptor]) {
        lock.withLock {
            var index = Dictionary(uniqueKeysWithValues: Self.builtIn.map { ($0.id, $0) })
            var accepted: [AgentDescriptor] = []
            for descriptor in descriptors where index[descriptor.id] == nil {
                index[descriptor.id] = descriptor
                accepted.append(descriptor)
            }
            extensionAgents = accepted
            byID = index
        }
    }

    // MARK: Built-in agents

    static let claude = AgentDescriptor(
        id: "claude",
        displayName: "Claude Code",
        launchCommand: "claude",
        resume: ResumeCommand(
            withSession: "claude --resume {session}",
            withoutSession: "claude --continue"),
        installation: AgentInstallation(
            commands: [
                AgentInstallCommand(manager: .homebrew, command: "brew install --cask claude-code"),
                AgentInstallCommand(manager: .npm, command: "npm install -g @anthropic-ai/claude-code"),
            ],
            documentation: URL(string: "https://code.claude.com/docs/en/setup")),
        icon: .asset("ClaudeIcon"),
        brandColour: .rgb(red: 0xd9 / 255, green: 0x77 / 255, blue: 0x57 / 255),
        keepsOriginalColours: false,
        settingsKeyToken: "Claude",
        hooks: .json(HooksIntegration.JSONHooks(
            directory: "~/.claude",
            fileName: "settings.json",
            key: "hooks",
            entryShape: .grouped,
            ownership: .shared,
            events: [
                .init("SessionStart", ""),
                .init("PreCompact", "compacting"),
                .init("PostCompact", "working"),
                .init("UserPromptSubmit", "working"),
                .init("PreToolUse", "working"),
                .init("PostToolUse", "working"),
                .init("PermissionRequest", "awaiting"),
                .init("Stop", "done"),
                .init("StopFailure", "failed"),
                .init("PermissionDenied", "denied"),
                .init("Notification", "notify"),
                .init("SessionEnd", "ended"),
            ],
            script: HooksIntegration.ScriptOptions(
                subdirectory: "hooks",
                sessionKeys: ["session_id"],
                stateFromPayload: HooksIntegration.PayloadStateRule(
                    key: "source", value: "compact", state: "compacting")),
            legacyScriptNames: ["ghostty-tab-state.sh"])),
        mcp: .json(MCPIntegration.JSONMCP(
            directory: "~",
            fileName: ".claude.json",
            key: "mcpServers",
            entry: MCPIntegration.Entry(
                command: .separateArguments,
                extras: ["type": .string("stdio")]))),
        sessions: .claudeProjects)

    static let codex = AgentDescriptor(
        id: "codex",
        displayName: "Codex",
        launchCommand: "codex",
        resume: ResumeCommand(
            withSession: "codex resume {session}",
            withoutSession: "codex resume --last"),
        installation: AgentInstallation(
            commands: [
                AgentInstallCommand(manager: .homebrew, command: "brew install --cask codex"),
                AgentInstallCommand(manager: .npm, command: "npm install -g @openai/codex"),
            ],
            documentation: URL(string: "https://developers.openai.com/codex/quickstart")),
        icon: .asset("CodexIcon"),
        brandColour: .artwork,
        keepsOriginalColours: false,
        settingsKeyToken: "Codex",
        hooks: .json(HooksIntegration.JSONHooks(
            directory: codexHome,
            fileName: "hooks.json",
            key: "hooks",
            entryShape: .grouped,
            ownership: .shared,
            events: [
                .init("SessionStart", ""),
                .init("UserPromptSubmit", "working"),
                .init("PreToolUse", "working"),
                .init("PostToolUse", "working"),
                .init("PermissionRequest", "awaiting"),
                .init("Stop", "done"),
                .init("SessionEnd", "ended"),
            ],
            script: HooksIntegration.ScriptOptions(
                subdirectory: "",
                sessionKeys: [
                    "session_id", "sessionId", "conversation_id", "conversationId", "thread_id",
                ]))),
        mcp: .toml(MCPIntegration.TOMLMCP(
            directory: codexHome,
            fileName: "config.toml",
            table: "mcp_servers",
            entry: MCPIntegration.Entry(command: .separateArguments))),
        sessions: .codexSessions)

    static let opencode = AgentDescriptor(
        id: "opencode",
        displayName: "OpenCode",
        launchCommand: "opencode",
        resume: ResumeCommand(
            withSession: "opencode --session {session}",
            withoutSession: "opencode --continue"),
        installation: AgentInstallation(
            commands: [
                /// The tap rather than the core formula, on the project's own
                /// advice: it calls the core one "maintained by the Homebrew
                /// team and updated less frequently".
                AgentInstallCommand(manager: .homebrew, command: "brew install anomalyco/tap/opencode"),
                AgentInstallCommand(manager: .npm, command: "npm install -g opencode-ai"),
            ],
            documentation: URL(string: "https://opencode.ai/docs/")),
        icon: .asset("OpenCodeIcon"),
        brandColour: .artwork,
        keepsOriginalColours: true,
        settingsKeyToken: "OpenCode",
        hooks: .file(HooksIntegration.PluginFile(
            directory: openCodeHome,
            subdirectory: "plugins",
            fileName: "phantom-integration.js",
            body: openCodePlugin,
            events: [
                "session.created", "session.status", "session.idle", "session.error",
                "permission.asked", "question.asked", "chat.message",
                "command.execute.before", "tool.execute.before", "permission.ask",
            ])),
        mcp: .json(MCPIntegration.JSONMCP(
            directory: openCodeHome,
            fileName: "opencode.json",
            key: "mcp",
            entry: MCPIntegration.Entry(
                command: .singleArray,
                extras: ["type": .string("local"), "enabled": .bool(true)]))),
        sessions: .openCodeDatabase)

    static let antigravity = AgentDescriptor(
        id: "antigravity",
        displayName: "Antigravity",
        launchCommand: "agy",
        resume: ResumeCommand(
            withSession: "agy --conversation {session}",
            withoutSession: "agy --continue"),
        /// Antigravity publishes one install for macOS and it is
        /// `curl -fsSL … | bash`. See `AgentInstallPlan` for why that is not
        /// offered from here.
        installation: AgentInstallation(
            commands: [],
            documentation: URL(string: "https://antigravity.google/docs/cli/install")),
        icon: .asset("AntigravityIcon"),
        brandColour: .asset("AntigravityIconColor"),
        keepsOriginalColours: false,
        settingsKeyToken: "Antigravity",
        hooks: .json(HooksIntegration.JSONHooks(
            directory: antigravityHome,
            fileName: "hooks.json",
            key: "phantom-tab-state",
            entryShape: .flat,
            ownership: .owned,
            events: [
                .init("PreInvocation", "working", reply: "{}"),
                .init("Stop", "done", reply: #"{"decision":"stop"}"#),
            ],
            script: HooksIntegration.ScriptOptions(
                subdirectory: "",
                sessionKeys: ["conversationId", "conversation_id", "sessionId", "session_id"]))),
        mcp: .json(MCPIntegration.JSONMCP(
            directory: antigravityHome,
            fileName: "mcp_config.json",
            key: "mcpServers",
            entry: MCPIntegration.Entry(command: .separateArguments))),
        sessions: .none)

    /// Kimi and Pi both spell the id-bearing form `--session`, and both also
    /// have a `--resume`. Kimi's `-r`/`--resume` is a hidden alias for
    /// `--session`, and Pi's opens a picker for the reader to choose from
    /// — a picker is the wrong thing for a tab restoring itself, which
    /// knows exactly which conversation it wants. So `--session` for both.
    static let kimi = AgentDescriptor(
        id: "kimi",
        displayName: "Kimi Code",
        launchCommand: "kimi",
        resume: ResumeCommand(
            withSession: "kimi --session {session}",
            withoutSession: "kimi --continue"),
        installation: AgentInstallation(
            commands: [
                AgentInstallCommand(manager: .npm, command: "npm install -g @moonshot-ai/kimi-code"),
            ],
            documentation: URL(
                string: "https://www.kimi.com/code/docs/en/kimi-code-cli/guides/getting-started.html")),
        icon: .asset("KimiIcon"),
        brandColour: .rgb(red: 0x01 / 255, green: 0x79 / 255, blue: 0xff / 255),
        keepsOriginalColours: false,
        settingsKeyToken: "Kimi",
        hooks: .toml(HooksIntegration.TOMLHooks(
            directory: kimiHome,
            fileName: "config.toml",
            table: "hooks",
            events: [
                .init("SessionStart", ""),
                .init("UserPromptSubmit", "working"),
                .init("PreToolUse", "working"),
                .init("PostToolUse", "working"),
                .init("PermissionRequest", "awaiting"),
                .init("Stop", "done"),
                .init("SessionEnd", "ended"),
            ],
            script: HooksIntegration.ScriptOptions(
                subdirectory: "",
                sessionKeys: ["session_id"]),
            timeout: 5)),
        mcp: .json(MCPIntegration.JSONMCP(
            directory: kimiHome,
            fileName: "mcp.json",
            key: "mcpServers",
            entry: MCPIntegration.Entry(command: .separateArguments))),
        sessions: .none)

    static let pi = AgentDescriptor(
        id: "pi",
        displayName: "Pi",
        launchCommand: "pi",
        resume: ResumeCommand(
            withSession: "pi --session {session}",
            withoutSession: "pi --continue"),
        installation: AgentInstallation(
            commands: [
                /// `--ignore-scripts` is the vendor's own spelling and is kept
                /// rather than tidied away: dropping it would install the same
                /// package a different way from the way its documentation says
                /// to.
                AgentInstallCommand(
                    manager: .npm,
                    command: "npm install -g --ignore-scripts @earendil-works/pi-coding-agent"),
            ],
            documentation: URL(string: "https://pi.dev/docs/latest/")),
        icon: .asset("PiIcon"),
        brandColour: .label,
        keepsOriginalColours: false,
        settingsKeyToken: "Pi",
        hooks: .file(HooksIntegration.PluginFile(
            directory: piHome,
            subdirectory: "extensions",
            fileName: "phantom.ts",
            body: piExtension,
            events: [
                "session_start", "agent_start", "tool_execution_start",
                "agent_end", "session_shutdown",
            ])),
        mcp: .json(MCPIntegration.JSONMCP(
            directory: piHome,
            fileName: "mcp.json",
            key: "mcpServers",
            entry: MCPIntegration.Entry(command: .separateArguments))),
        sessions: .none)

    // MARK: Plugin bodies

    static let openCodePlugin = #"""
    import { writeFileSync, renameSync, unlinkSync, readFileSync } from "fs";

    let writeChain = Promise.resolve();
    let sessionId = "";

    // The id ends up typed at a shell prompt after `opencode --session`, so
    // anything a shell would read as more than one word is refused — and so
    // is anything starting with a dash, which would arrive there as a flag.
    function remember(candidate) {
      if (typeof candidate === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(candidate)) {
        sessionId = candidate;
      }
    }

    function sessionIdFrom(event) {
      const props = event?.properties || {};
      return props.sessionID || props.sessionId || props.session_id ||
        props.info?.sessionID || props.info?.id || props.session?.id || "";
    }

    // A subagent runs in a session of its own, a child of the tab's, and
    // resuming by a child's id opens that thread rather than the conversation
    // the tab was holding. `Session.parentID` is what separates them, and the
    // events that carry a whole `info` object are the ones that can be asked.
    function isSubSession(event) {
      const info = event?.properties?.info;
      return Boolean(info && (info.parentID || info.parentId));
    }

    // The id already on record, for a process that has not learned one yet.
    //
    // Every write here rewrites the whole file, so without this the first write
    // of a freshly loaded plugin drops the `session=` line that was in it — and
    // several of the handlers below report a state without any event having
    // carried an id first. The write that follows a restore is exactly that
    // shape, and the id it would drop is the only record of which conversation
    // the tab was resumed into. Passing it back through `remember` rather than
    // straight into the file means the value read off disk faces the same
    // filter a value off the wire does, so a corrupt line cannot be copied
    // forward indefinitely.
    function carriedSession(file) {
      try {
        const carried = readFileSync(file, "utf8")
          .split("\n")
          .find((line) => line.startsWith("session="));
        return carried ? carried.slice("session=".length).trim() : "";
      } catch {
        return "";
      }
    }

    function state(value) {
      const file = process.env.{{stateFileVariable}};
      if (!file) return;
      if (!sessionId) remember(carriedSession(file));
      // State stays alone on the first line: a Phantom old enough to read
      // only that line keeps reading this file correctly.
      const lines = [value, "agent={{agent}}"];
      if (sessionId) lines.push(`session=${sessionId}`);
      const body = lines.join("\n") + "\n";
      // OpenCode can emit busy -> idle -> idle in one turn. Serialize the
      // atomic writes so a late busy event cannot leave Phantom spinning.
      writeChain = writeChain.then(() => {
        // A temp name private to this process. Serializing the chain orders
        // this plugin's own writes, and does nothing about anyone else's: a
        // fixed `.tmp` is one path shared with whatever else writes this tab —
        // a Claude or Codex hook in the same terminal, another integration on
        // the same events — and two writers truncating that one file
        // interleave their bytes, so the rename that wins carries the mixture
        // and a `session=` line comes back cut in half.
        //
        // The name still cannot be mistaken for a state file: TabStateCenter
        // reads only entries whose whole name parses as a UUID.
        const tmp = `${file}.${process.pid}.tmp`;
        try {
          writeFileSync(tmp, body, "utf8");
          renameSync(tmp, file);
        } catch {
          try { unlinkSync(tmp); } catch {}
        }
      }).catch(() => {});
    }

    function statusType(event) {
      return event?.properties?.status?.type || event?.status?.type || event?.status || "";
    }

    export const PhantomPlugin = async () => ({
      event: async ({ event }) => {
        if (!isSubSession(event)) remember(sessionIdFrom(event));
        const type = event?.type || "";
        if (type === "session.created") {
          // OpenCode's answer to a session-start hook. It carries the id in
          // `properties.sessionID` on one SDK generation and
          // `properties.info.id` on the other, both of which `sessionIdFrom`
          // already reads, and it fires before the user has asked for
          // anything — so the tab holds its id from the moment it opens
          // rather than from its first prompt.
          //
          // Written with no state word: a session that has just been created
          // is not working, and this is the record saying which conversation
          // the tab holds, not what it is doing.
          state("");
        } else if (type === "session.status") {
          const status = statusType(event);
          if (status === "busy" || status === "retry") state("working");
          else if (status === "idle") state("done");
        } else if (type === "session.idle") {
          state("done");
        } else if (
          type === "session.error" ||
          type === "permission.asked" ||
          type === "question.asked"
        ) {
          state("awaiting");
        }
      },
      "chat.message": async (_input, output) => {
        remember(output?.message?.sessionID);
        state("working");
      },
      "command.execute.before": async () => state("working"),
      "tool.execute.before": async () => state("working"),
      "permission.ask": async () => state("awaiting"),
    });
    """#

    static let piExtension = #"""
    // Reports Pi session state to the Phantom sidebar.
    //
    // Managed by Phantom. Delete it from the app's Settings rather than by
    // hand, so the app stops believing it is installed.
    import { writeFileSync, renameSync, unlinkSync } from "node:fs";

    export default function (pi) {
      const stateFile = process.env.{{stateFileVariable}};
      if (!stateFile) return;

      let session = "";

      // The id is the session file's own name. A path would be refused by the
      // app on read, and a leading dash is a flag rather than an id once it
      // reaches `pi --session`.
      const idFrom = (file) => {
        if (!file) return "";
        const base = String(file).split("/").pop() || "";
        const stem = base.replace(/\.[^.]*$/, "");
        if (!stem) return "";

        // The UUID pi will match on, wherever it sits in the name. Falling
        // back to the whole stem rather than to nothing keeps a naming scheme
        // this does not recognise working the way it did.
        const uuid = stem.match(
          /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
        );
        const id = uuid ? uuid[0] : stem;

        // A leading dash is a flag rather than an id once it reaches
        // `pi --session`.
        if (id.startsWith("-")) return "";
        return /^[A-Za-z0-9._-]+$/.test(id) ? id : "";
      };

      // A temp name private to this process, then a rename. A fixed name is one
      // path shared by everything writing this tab, and two writers truncating
      // it interleave their bytes — which is how a session line arrives cut in
      // half. The app reads only entries whose whole name is a UUID, so this
      // name is never mistaken for a state file.
      const report = (state) => {
        const temp = stateFile + "." + process.pid + ".tmp";
        let body = state + "\nagent={{agent}}\n";
        if (session) body += "session=" + session + "\n";
        try {
          writeFileSync(temp, body);
          renameSync(temp, stateFile);
        } catch (error) {
          try {
            unlinkSync(temp);
          } catch (ignored) {
            // Nothing to clean up, which is the common case.
          }
        }
      };

      pi.on("session_start", async (_event, ctx) => {
        const file = ctx && ctx.sessionManager && ctx.sessionManager.getSessionFile
          ? ctx.sessionManager.getSessionFile()
          : null;
        session = idFrom(file) || session;
        report("");
      });

      pi.on("agent_start", async () => report("working"));
      pi.on("tool_execution_start", async () => report("working"));
      pi.on("agent_end", async () => report("done"));
      pi.on("session_shutdown", async () => report("ended"));
    }
    """#
}
