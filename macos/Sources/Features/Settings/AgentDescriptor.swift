import Foundation

struct AgentDescriptor: Equatable, Sendable {
    let id: String
    let displayName: String
    let launchCommand: String
    let resume: ResumeCommand
    let installation: AgentInstallation
    let icon: AgentIcon
    let brandColour: AgentBrandColour
    let keepsOriginalColours: Bool

    /// The agent's spelling inside a button preference key, which is **not**
    /// its display name and not its id.
    ///
    /// `OpenCode` is the one that decides the shape: the display name has no
    /// space to drop and the id capitalises to `Opencode`, so neither
    /// derivation produces the key that is already on disk. Written out, so
    /// every one of the six is a decision rather than a coincidence that holds
    /// for five of them.
    let settingsKeyToken: String
    let hooks: HooksIntegration?
    let mcp: MCPIntegration?
    let sessions: SessionDiscovery

    static func placeholder(id: String) -> AgentDescriptor {
        AgentDescriptor(
            id: id,
            displayName: id,
            launchCommand: id,
            resume: ResumeCommand(
                withSession: "\(id) --resume \(ResumeCommand.sessionPlaceholder)",
                withoutSession: id),
            installation: AgentInstallation(commands: [], documentation: nil),
            icon: .symbol("sparkles"),
            brandColour: .label,
            keepsOriginalColours: false,
            settingsKeyToken: id,
            hooks: nil,
            mcp: nil,
            sessions: .none)
    }
}

struct ResumeCommand: Equatable, Sendable {
    static let sessionPlaceholder = "{session}"

    let withSession: String
    let withoutSession: String

    func command(sessionID: String?) -> String {
        guard let sessionID, !sessionID.isEmpty else { return withoutSession }
        return withSession.replacingOccurrences(of: Self.sessionPlaceholder, with: sessionID)
    }
}

struct AgentInstallation: Equatable, Sendable {
    let commands: [AgentInstallCommand]
    let documentation: URL?
}

enum AgentIcon: Equatable, Sendable {
    case asset(String)
    case file(URL)
    case symbol(String)
}

enum AgentBrandColour: Equatable, Sendable {
    case artwork
    case asset(String)
    case rgb(red: Double, green: Double, blue: Double)
    case label
}

enum SessionDiscovery: Equatable, Sendable {
    case claudeProjects
    case codexSessions
    case openCodeDatabase
    case none
}

enum HooksIntegration: Equatable, Sendable {
    case json(JSONHooks)
    case toml(TOMLHooks)
    case file(PluginFile)

    struct Event: Equatable, Sendable {
        let name: String
        let state: String
        var reply: String?

        init(_ name: String, _ state: String, reply: String? = nil) {
            self.name = name
            self.state = state
            self.reply = reply
        }
    }

    struct PayloadStateRule: Equatable, Sendable {
        let key: String
        let value: String
        let state: String
    }

    struct ScriptOptions: Equatable, Sendable {
        let subdirectory: String
        let sessionKeys: [String]
        var stateFromPayload: PayloadStateRule?
    }

    struct JSONHooks: Equatable, Sendable {
        enum EntryShape: Equatable, Sendable {
            case grouped
            case flat
        }

        enum KeyOwnership: Equatable, Sendable {
            case shared
            case owned
        }

        let directory: ConfigPath
        let fileName: String
        let key: String
        let entryShape: EntryShape
        let ownership: KeyOwnership
        let events: [Event]
        let script: ScriptOptions
        var legacyScriptNames: [String] = []
    }

    struct TOMLHooks: Equatable, Sendable {
        let directory: ConfigPath
        let fileName: String
        let table: String
        let events: [Event]
        let script: ScriptOptions
        let timeout: Int
    }

    struct PluginFile: Equatable, Sendable {
        static let agentPlaceholder = "{{agent}}"
        static let stateFileVariablePlaceholder = "{{stateFileVariable}}"

        let directory: ConfigPath
        let subdirectory: String
        let fileName: String
        let body: String
        let events: [String]
    }

    var hookEvents: [Event] {
        switch self {
        case .json(let hooks): return hooks.events
        case .toml(let hooks): return hooks.events
        case .file: return []
        }
    }

    var events: [String] {
        switch self {
        case .json(let hooks): return hooks.events.map(\.name)
        case .toml(let hooks): return hooks.events.map(\.name)
        case .file(let plugin): return plugin.events
        }
    }
}

enum MCPIntegration: Equatable, Sendable {
    case json(JSONMCP)
    case toml(TOMLMCP)

    struct Entry: Equatable, Sendable {
        enum Command: Equatable, Sendable {
            case separateArguments
            case singleArray
        }

        enum Extra: Equatable, Sendable {
            case string(String)
            case bool(Bool)
        }

        let command: Command
        var extras: [String: Extra] = [:]
    }

    struct JSONMCP: Equatable, Sendable {
        let directory: ConfigPath
        let fileName: String
        let key: String
        let entry: Entry
    }

    struct TOMLMCP: Equatable, Sendable {
        let directory: ConfigPath
        let fileName: String
        let table: String
        let entry: Entry
    }
}
