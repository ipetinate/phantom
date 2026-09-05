import Foundation

enum AgentContribution {
    static let maxAgents = 16
    static let maxEvents = 64
    static let maxSessionKeys = 16
    static let maxDirectoryCandidates = 8
    static let maxInstallCommands = 8
    static let maxExtras = 16
    static let maxTemplateBytes = 256 * 1024
    static let maxCommandLineLength = 256
    static let maxDisplayNameLength = 64

    static let forbiddenInstallFragments = ["curl", "sudo", "|", ";", "&", "$(", "`", "<", ">"]
    static let reservedEntryKeys: Set<String> = ["command", "args"]
    static let artworkColourWord = "artwork"
    static let defaultSessionKeys = ["session_id"]
    static let defaultTOMLTimeout = 5
    static let timeoutRange = 1...600

    static func parse(json: [String: Any], root: URL) -> AgentDescriptor? {
        guard let id = validAgentID(json["agentId"]),
              let name = LanguageManifest.displayString(json["name"]),
              name.count <= maxDisplayNameLength,
              let command = LanguageManifest.string(json["command"]),
              LanguageServerContribution.isLaunchable(command)
        else { return nil }

        let placeholder = AgentDescriptor.placeholder(id: id)
        return AgentDescriptor(
            id: id,
            displayName: name,
            launchCommand: command,
            resume: resume(json["resume"], command: command) ?? placeholder.resume,
            installation: installation(json["install"]),
            icon: LanguageContribution.containedURL(json["icon"], root: root).map(AgentIcon.file)
                ?? placeholder.icon,
            brandColour: brandColour(json["brandColour"]),
            keepsOriginalColours: bool(json["keepsOriginalColours"]) ?? false,
            settingsKeyToken: id,
            hooks: hooks(json["hooks"], root: root),
            mcp: mcp(json["mcp"]),
            sessions: .none)
    }

    static func validAgentID(_ value: Any?) -> String? {
        LanguageContribution.validLanguageID(value)
    }

    // MARK: Commands

    static func resume(_ value: Any?, command: String) -> ResumeCommand? {
        guard let json = value as? [String: Any],
              let withSession = commandLine(json["withSession"], command: command),
              withSession.contains(ResumeCommand.sessionPlaceholder)
        else { return nil }
        return ResumeCommand(
            withSession: withSession,
            withoutSession: commandLine(json["withoutSession"], command: command) ?? command)
    }

    static func commandLine(_ value: Any?, command: String) -> String? {
        guard let raw = LanguageManifest.string(value), raw.count <= maxCommandLineLength else {
            return nil
        }
        let words = raw.split(separator: " ").map(String.init)
        guard words.first == command, words.allSatisfy(isCommandLineWord) else { return nil }
        return words.joined(separator: " ")
    }

    private static let commandLineScalars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:=/-+@%,"
    )

    static func isCommandLineWord(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        return word
            .replacingOccurrences(of: ResumeCommand.sessionPlaceholder, with: "")
            .unicodeScalars
            .allSatisfy(commandLineScalars.contains)
    }

    static func installation(_ value: Any?) -> AgentInstallation {
        guard let json = value as? [String: Any] else {
            return AgentInstallation(commands: [], documentation: nil)
        }
        let commands = (json["commands"] as? [Any] ?? [])
            .compactMap { $0 as? String }
            .compactMap(installCommand)
            .prefix(maxInstallCommands)
        return AgentInstallation(
            commands: Array(commands),
            documentation: LanguageServerContribution.documentationURL(json["documentationURL"]))
    }

    static func installCommand(_ raw: String) -> AgentInstallCommand? {
        let command = raw.trimmingCharacters(in: .whitespaces)
        guard command.count <= maxCommandLineLength,
              !command.unicodeScalars.contains(where: LanguageContribution.isUnsafeScalar),
              !forbiddenInstallFragments.contains(where: command.contains),
              let manager = AgentPackageManager.allCases.first(where: {
                  command.hasPrefix($0.command + " ")
              })
        else { return nil }
        return AgentInstallCommand(manager: manager, command: command)
    }

    // MARK: Appearance

    static func brandColour(_ value: Any?) -> AgentBrandColour {
        guard let raw = LanguageManifest.string(value) else { return .label }
        if raw == artworkColourWord { return .artwork }
        let digits = raw.dropFirst()
        guard raw.hasPrefix("#"), digits.count == 6, digits.allSatisfy(\.isHexDigit),
              let rgb = UInt32(digits, radix: 16)
        else { return .label }
        return .rgb(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255)
    }

    // MARK: Scalars

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID()
        else { return nil }
        return Int(exactly: number.doubleValue)
    }

    private static func word<Value>(
        _ value: Any?,
        default fallback: Value,
        in table: [String: Value]
    ) -> Value? {
        guard let value else { return fallback }
        guard let raw = LanguageManifest.string(value) else { return nil }
        return table[raw]
    }

    private static let keyScalars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-"
    )

    static func plainKey(_ value: Any?) -> String? {
        guard let raw = LanguageManifest.string(value), raw.count <= 64,
              raw.unicodeScalars.allSatisfy(keyScalars.contains)
        else { return nil }
        return raw
    }

    static func isVariableName(_ name: Substring) -> Bool {
        guard let first = name.first, first.isASCII, first == "_" || first.isLetter else {
            return false
        }
        return name.allSatisfy { $0.isASCII && ($0 == "_" || $0.isLetter || $0.isNumber) }
    }

    // MARK: Paths

    static func configPath(_ value: Any?) -> ConfigPath? {
        let raw: [Any]
        if let single = value as? String {
            raw = [single]
        } else if let list = value as? [Any] {
            raw = list
        } else {
            return nil
        }
        guard !raw.isEmpty, raw.count <= maxDirectoryCandidates else { return nil }
        let candidates = raw.compactMap { ($0 as? String).flatMap(directoryCandidate) }
        guard candidates.count == raw.count else { return nil }
        return ConfigPath(candidates)
    }

    static func directoryCandidate(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= maxCommandLineLength,
              !raw.unicodeScalars.contains(where: LanguageContribution.isUnsafeScalar),
              !raw.contains("\\"),
              !raw.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                  .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return nil }
        if raw == "~" || raw.hasPrefix("~/") { return raw }
        guard raw.hasPrefix("$") else { return nil }
        return isVariableName(raw.dropFirst().prefix { $0 != "/" }) ? raw : nil
    }

    static func configFileName(_ value: Any?) -> String? {
        guard let raw = LanguageManifest.string(value), raw.count <= 128,
              raw != ".", raw != "..", !raw.contains("/"), !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: LanguageContribution.isUnsafeScalar)
        else { return nil }
        return raw
    }

    static func relativeSubdirectory(_ value: Any?) -> String? {
        guard let value else { return "" }
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.count <= 128,
              !trimmed.unicodeScalars.contains(where: LanguageContribution.isUnsafeScalar),
              !trimmed.contains("\\"),
              !trimmed.split(separator: "/", omittingEmptySubsequences: false)
                  .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return nil }
        return trimmed
    }

    static func templateBody(_ value: Any?, root: URL) -> String? {
        guard let url = LanguageContribution.containedURL(value, root: root),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= maxTemplateBytes,
              let data = try? Data(contentsOf: url),
              data.count <= maxTemplateBytes
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Events

    private static let eventNameScalars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-"
    )

    static func eventName(_ value: Any?) -> String? {
        guard let raw = LanguageManifest.string(value), raw.count <= 64,
              raw.unicodeScalars.allSatisfy(eventNameScalars.contains)
        else { return nil }
        return raw
    }

    static func isStateWord(_ word: String) -> Bool {
        word.isEmpty || AgentTabState(rawValue: word) != nil || word == TabStateCenter.notifyMarker
    }

    static func stateWord(_ value: Any?) -> String? {
        guard let value else { return "" }
        guard let raw = value as? String else { return nil }
        let word = raw.trimmingCharacters(in: .whitespaces)
        return isStateWord(word) ? word : nil
    }

    static func replyText(_ value: Any) -> String? {
        guard let raw = value as? String, !raw.isEmpty, raw.count <= maxCommandLineLength,
              !raw.unicodeScalars.contains(where: LanguageContribution.isUnsafeScalar)
        else { return nil }
        return raw
    }

    static func hookEvent(_ json: [String: Any]) -> HooksIntegration.Event? {
        guard let name = eventName(json["name"]), let state = stateWord(json["state"]) else {
            return nil
        }
        var event = HooksIntegration.Event(name, state)
        if let rawReply = json["reply"] {
            guard let reply = replyText(rawReply) else { return nil }
            event.reply = reply
        }
        return event
    }

    static func hookEvents(_ value: Any?) -> [HooksIntegration.Event] {
        var seen: Set<String> = []
        return (value as? [Any] ?? [])
            .prefix(maxEvents)
            .compactMap { $0 as? [String: Any] }
            .compactMap(hookEvent)
            .filter { seen.insert($0.name).inserted }
    }

    static func eventNames(_ value: Any?) -> [String] {
        var seen: Set<String> = []
        return (value as? [Any] ?? [])
            .prefix(maxEvents)
            .compactMap { eventName($0) }
            .filter { seen.insert($0).inserted }
    }

    static func scriptOptions(_ value: Any?) -> HooksIntegration.ScriptOptions? {
        let json = value as? [String: Any] ?? [:]
        guard let subdirectory = relativeSubdirectory(json["subdirectory"]) else { return nil }
        let keys = (json["sessionKeys"] as? [Any] ?? [])
            .compactMap { plainKey($0) }
            .prefix(maxSessionKeys)
        return HooksIntegration.ScriptOptions(
            subdirectory: subdirectory,
            sessionKeys: keys.isEmpty ? defaultSessionKeys : Array(keys),
            stateFromPayload: payloadStateRule(json["stateFromPayload"]))
    }

    static func payloadStateRule(_ value: Any?) -> HooksIntegration.PayloadStateRule? {
        guard let json = value as? [String: Any],
              let key = plainKey(json["key"]),
              let expected = plainKey(json["value"]),
              let state = stateWord(json["state"]), !state.isEmpty
        else { return nil }
        return HooksIntegration.PayloadStateRule(key: key, value: expected, state: state)
    }

    // MARK: Hooks

    private static let entryShapes: [String: HooksIntegration.JSONHooks.EntryShape] = [
        "grouped": .grouped, "flat": .flat,
    ]

    private static let ownerships: [String: HooksIntegration.JSONHooks.KeyOwnership] = [
        "shared": .shared, "owned": .owned,
    ]

    static func tomlTimeout(_ value: Any?) -> Int? {
        guard let value else { return defaultTOMLTimeout }
        guard let seconds = integer(value), timeoutRange.contains(seconds) else { return nil }
        return seconds
    }

    static func hooks(_ value: Any?, root: URL) -> HooksIntegration? {
        guard let json = value as? [String: Any],
              let kind = LanguageManifest.string(json["kind"]),
              let directory = configPath(json["directory"]),
              let fileName = configFileName(json["fileName"])
        else { return nil }

        switch kind {
        case "json":
            guard let key = plainKey(json["key"]),
                  let entryShape = word(json["entryShape"], default: .grouped, in: entryShapes),
                  let ownership = word(json["ownership"], default: .shared, in: ownerships),
                  let script = scriptOptions(json["script"])
            else { return nil }
            let events = hookEvents(json["events"])
            guard !events.isEmpty else { return nil }
            return .json(HooksIntegration.JSONHooks(
                directory: directory,
                fileName: fileName,
                key: key,
                entryShape: entryShape,
                ownership: ownership,
                events: events,
                script: script))
        case "toml":
            guard let table = plainKey(json["table"]),
                  let script = scriptOptions(json["script"]),
                  let timeout = tomlTimeout(json["timeout"])
            else { return nil }
            let events = hookEvents(json["events"])
            guard !events.isEmpty else { return nil }
            return .toml(HooksIntegration.TOMLHooks(
                directory: directory,
                fileName: fileName,
                table: table,
                events: events,
                script: script,
                timeout: timeout))
        case "file":
            guard let subdirectory = relativeSubdirectory(json["subdirectory"]),
                  let body = templateBody(json["template"], root: root)
            else { return nil }
            return .file(HooksIntegration.PluginFile(
                directory: directory,
                subdirectory: subdirectory,
                fileName: fileName,
                body: body,
                events: eventNames(json["events"])))
        default:
            return nil
        }
    }

    // MARK: MCP

    private static let entryCommands: [String: MCPIntegration.Entry.Command] = [
        "separateArguments": .separateArguments, "singleArray": .singleArray,
    ]

    static func mcp(_ value: Any?) -> MCPIntegration? {
        guard let json = value as? [String: Any],
              let kind = LanguageManifest.string(json["kind"]),
              let directory = configPath(json["directory"]),
              let fileName = configFileName(json["fileName"]),
              let entry = mcpEntry(json["entry"])
        else { return nil }

        switch kind {
        case "json":
            guard let key = plainKey(json["key"]) else { return nil }
            return .json(MCPIntegration.JSONMCP(
                directory: directory, fileName: fileName, key: key, entry: entry))
        case "toml":
            guard let table = plainKey(json["table"]) else { return nil }
            return .toml(MCPIntegration.TOMLMCP(
                directory: directory, fileName: fileName, table: table, entry: entry))
        default:
            return nil
        }
    }

    static func mcpEntry(_ value: Any?) -> MCPIntegration.Entry? {
        let json = value as? [String: Any] ?? [:]
        guard let command = word(json["command"], default: .separateArguments, in: entryCommands)
        else { return nil }

        let rawExtras = json["extras"] as? [String: Any] ?? [:]
        guard rawExtras.count <= maxExtras else { return nil }
        var extras: [String: MCPIntegration.Entry.Extra] = [:]
        for (name, raw) in rawExtras {
            guard plainKey(name) != nil, !reservedEntryKeys.contains(name) else { return nil }
            if let flag = bool(raw) {
                extras[name] = .bool(flag)
            } else if let text = raw as? String, text.count <= maxCommandLineLength,
                      !text.unicodeScalars.contains(where: LanguageContribution.isUnsafeScalar) {
                extras[name] = .string(text)
            } else {
                return nil
            }
        }
        return MCPIntegration.Entry(command: command, extras: extras)
    }
}
