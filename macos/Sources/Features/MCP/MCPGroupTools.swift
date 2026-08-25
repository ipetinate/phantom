import AppKit
import Foundation

/// The group tools: how an agent files the reader's terminals.
///
/// A sidebar group is one app-wide thing — `SidebarGroupStore.shared` — rather
/// than a window's, so these two tools need no window. What they do need is a
/// terminal that exists, which is why the store is not reached for directly:
/// an assignment written for an id that names no tab is a row nobody can see
/// and nobody can undo.
///
/// `list_groups` is not here. It belongs with the terminals, because it is a
/// listing of tabs — the groups are how it sorts them.
///
/// ## Permission: neither of these asks, and that is a decision
///
/// The capabilities are `read` — a terminal's scrollback — and `run` — typing
/// into a shell. A group holds neither. It is a name, an icon and a folder
/// path over tabs that already exist, and nothing about it reaches the pty.
/// A third capability is not invented here: the spec closed that list, and the
/// reader's consent is worth more when it covers few enough things to be held
/// in the head.
///
/// A group *is* the reader's own arrangement of their work, which is the
/// argument for asking. It is answered by what happens when the agent gets it
/// wrong: a new section appears in the sidebar, or a tab moves one section up.
/// Both are on screen at once, neither loses anything, and either is undone by
/// the menu the reader already has. The prompt is kept for the two things that
/// cannot be undone by looking at them — what was on the screen, and what was
/// typed into the shell.
@MainActor
enum MCPGroupTools {
    static var all: [MCPToolHandler] {
        all(store: .shared) { id in
            MCPWindows.surface(id).map { Terminal(title: $0.title, pwd: $0.pwd) }
        }
    }

    /// What a group tool needs to know about a terminal: enough to say it
    /// exists, and enough to name it back to the caller.
    struct Terminal {
        var title: String
        var pwd: String?
    }

    /// The tools against a store and a way to find a terminal.
    ///
    /// The seam every test uses. `SidebarGroupStore` takes a file of its own,
    /// so a test never touches the reader's real sidebar, and a terminal is a
    /// value rather than a window.
    static func all(
        store: SidebarGroupStore,
        terminal: @escaping (UUID) -> Terminal?
    ) -> [MCPToolHandler] {
        [
            listGroups(store),
            listThemeColors(),
            createGroup(store),
            updateGroup(store),
            moveToGroup(store, terminal),
        ]
    }


    /// One group, as every tool here answers it.
    ///
    /// Written once because three tools answer with a group and a model that
    /// learned the shape from one must not be surprised by another.
    static func describe(_ group: SidebarGroup) -> JSONValue {
        .object([
            "id": .string(group.id.uuidString),
            "name": .string(group.name),
            "description": group.details.map { .string($0) } ?? .null,
            "icon": .string(group.icon),
            "color": .string(group.color.localizedName.lowercased()),
            "project_root": group.projectRoot.map { .string($0) } ?? .null,
        ])
    }

    /// The palette, so a model asked for "magenta" can pick the nearest thing
    /// that exists instead of guessing at a name.
    ///
    /// Answers both halves: the named colours a group or a tab can be set to,
    /// and the current theme's own sixteen, which is what the reader sees in
    /// the app's picker. Asks nothing — a theme's colours are not anybody's
    /// output.
    private static func listThemeColors() -> MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "list_theme_colors",
                description: """
                    List the colours a group or a terminal can be set to, each with its \
                    hex value, plus the colours of the theme the reader is using. Call it \
                    when you have been asked for a colour by name — “magenta”, “the same \
                    as the prompt” — so you can pick the nearest one that exists rather \
                    than guessing at a name that will be refused.
                    """,
                schema: MCPSchema.object([:])),
            run: { _, answer in
                let named = TerminalTabColor.allCases.map { colour -> JSONValue in
                    .object([
                        "name": .string(colour.localizedName.lowercased()),
                        "hex": colour.displayColor.map { .string(MCPColors.hex(of: $0)) } ?? .null,
                    ])
                }

                let theme = ThemePalette.shared.colors.enumerated().map { index, colour in
                    JSONValue.object([
                        "index": .number(Double(index)),
                        "hex": .string(MCPColors.hex(of: colour)),
                    ])
                }

                answer(.json(.object([
                    "colors": .array(named),
                    "theme_colors": .array(theme),
                ])))
            })
    }

    /// A colour as `#rrggbb`, converted through sRGB because a theme's
    /// colours arrive in whatever space the palette was parsed in, and
    /// `redComponent` traps on a colour that has none.
    static func hex(of colour: NSColor) -> String {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02x%02x%02x",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded()))
    }

    /// Changes a group that already exists.
    ///
    /// Every field is optional and only what is given changes: a model that
    /// wanted to add a description must not have to resend the icon it does
    /// not know. An empty string is how a description is *cleared*, which is
    /// different from leaving it out.
    private static func updateGroup(_ store: SidebarGroupStore) -> MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "update_group",
                description: """
                    Change a sidebar group that already exists: its name, description, \
                    icon, colour, or the project folder it claims terminals from. Only \
                    what you pass changes. Use it to finish a group you created without \
                    every detail, or when the reader asks for a different name or colour. \
                    Pass an empty string for “description” to remove one.
                    """,
                schema: MCPSchema.object(
                    [
                        "group": MCPSchema.string(
                            "The group's id, as list_groups hands it out."),
                        "name": MCPSchema.string("A new name for the section."),
                        "description": MCPSchema.string(
                            "A new second line, or an empty string to remove it."),
                        "icon": MCPSchema.string(
                            "An SF Symbol name, a single emoji, or “agent:” and an "
                            + "agent's name."),
                        "color": MCPSchema.enumeration(
                            "A colour from list_theme_colors. “none” removes it.",
                            MCPColors.names),
                        "project_root": MCPSchema.string(
                            "Absolute path of the folder this group claims terminals "
                            + "from."),
                    ],
                    required: ["group"])
            )
        ) { context, answer in
            guard let id = context.surface("group") else {
                return answer(.refused(idRefusal(
                    context.string("group"), argument: "group", from: "list_groups")))
            }

            guard store.groups.contains(where: { $0.id == id }) else {
                return answer(.refused(
                    "Phantom has no group with id \(id.uuidString). Call list_groups for "
                    + "the ones it has."))
            }

            let icon = context.string("icon")?.trimmingCharacters(in: .whitespaces)
            if let icon, !icon.isEmpty, let refusal = iconRefusal(icon) {
                return answer(.refused(refusal))
            }

            var colour: TerminalTabColor?
            if let asked = context.string("color"), !asked.isEmpty {
                guard let found = MCPColors.named(asked) else {
                    return answer(.refused(MCPColors.refusal(asked)))
                }
                colour = found
            }

            var kind: SidebarGroup.Kind?
            if let asked = context.string("project_root"), !asked.isEmpty {
                switch root(asked) {
                case .refused(let refusal):
                    return answer(.refused(refusal))
                case .path(let path):
                    kind = .project(root: path)
                }
            }

            let name = context.string("name")?.trimmingCharacters(in: .whitespaces)
            if let name, name.isEmpty {
                return answer(.refused(
                    "A group cannot be renamed to nothing. Leave “name” out to keep the "
                    + "one it has."))
            }

            let details = context.string("description")

            store.update(id) { group in
                if let name, !name.isEmpty { group.name = name }
                if let details { group.details = details.isEmpty ? nil : details }
                if let icon, !icon.isEmpty { group.icon = icon }
                if let colour { group.color = colour }
                if let kind { group.kind = kind }
            }

            guard let updated = store.groups.first(where: { $0.id == id }) else {
                return answer(.refused("The group went away while it was being changed."))
            }

            answer(.json(describe(updated)))
        }
    }

    // MARK: The tools

    /// The groups, and which terminals are filed under each.
    ///
    /// Asks nothing of the reader, for the reason `list_terminals` does not:
    /// this is the app's own structure — the sections of a sidebar — and not
    /// anyone's output. It is also the tool every refusal in this file points
    /// at, so a model that used the wrong id has somewhere to look.
    private static func listGroups(_ store: SidebarGroupStore) -> MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "list_groups",
                description: """
                    List the reader's sidebar groups: the named sections their terminals \
                    are filed under. Each answers with its id, which is what \
                    move_to_group and create_terminal take, and with the terminals \
                    currently in it. Use it before filing a terminal, and whenever a \
                    group id you were given is refused.
                    """,
                schema: MCPSchema.object([:])),
            run: { _, answer in
                let groups = store.groups.map { group in
                    JSONValue.object([
                        "id": .string(group.id.uuidString),
                        "name": .string(group.name),
                        "icon": .string(group.icon),
                        "project_root": group.projectRoot.map { .string($0) } ?? .null,
                        "terminals": .array(
                            MCPWindows.surfaces()
                                .filter {
                                    store.resolveGroup(surfaceId: $0.id, pwd: $0.pwd)?.id
                                        == group.id
                                }
                                .map { .string($0.id.uuidString) }),
                    ])
                }

                answer(.json(.object([
                    "groups": .array(groups),
                    "count": .number(Double(groups.count)),
                ])))
            })
    }

    private static func createGroup(_ store: SidebarGroupStore) -> MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "create_group",
                description: """
                    Create a sidebar group: the named section the reader's terminals are \
                    filed under. Use it when you are starting a piece of work that will \
                    need more than one terminal — before you create them, so they can be \
                    filed as they appear. Give it a project root and the group claims \
                    every terminal working inside that folder on its own. It answers with \
                    the group's id, which is what move_to_group takes.
                    """,
                schema: MCPSchema.object(
                    [
                        "name": MCPSchema.string(
                            "What the section is called in the sidebar. Name it for the "
                            + "work, the way the reader would."),
                        "icon": MCPSchema.string(
                            "An SF Symbol name, a single emoji, or “agent:” and one of "
                            + "\(agents) for that agent's mark. Defaults to “folder”."),
                        "description": MCPSchema.string(
                            "A second line under the name, for what the work is. Leave "
                            + "it out for a group whose name says enough."),
                        "color": MCPSchema.enumeration(
                            "The group's colour. Call list_theme_colors to see them "
                            + "with their hex values, and pick the nearest to what the "
                            + "reader asked for.", MCPColors.names),
                        "project_root": MCPSchema.string(
                            "Absolute path of the project folder, if this group is a "
                            + "project. Every terminal whose working directory is inside "
                            + "it joins the group with no assignment. Leave it out for a "
                            + "group the reader fills by hand."),
                    ],
                    required: ["name"])
            )
        ) { context, answer in
            let name = (context.string("name") ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                return answer(.refused(
                    "create_group needs a “name”: what the section is called in the "
                    + "sidebar."))
            }

            if let existing = store.groups.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                return answer(.refused(
                    "Phantom already has a group called “\(existing.name)”, with id "
                    + "\(existing.id.uuidString). Move terminals into that one with "
                    + "move_to_group, or choose another name."))
            }

            let icon = context.string("icon")?.trimmingCharacters(in: .whitespaces) ?? ""
            if let refusal = iconRefusal(icon) { return answer(.refused(refusal)) }

            var kind = SidebarGroup.Kind.manual
            if let asked = context.string("project_root"), !asked.isEmpty {
                switch root(asked) {
                case .refused(let refusal):
                    return answer(.refused(refusal))
                case .path(let root):
                    kind = .project(root: root)
                }
            }

            var chosen = TerminalTabColor.none
            if let asked = context.string("color"), !asked.isEmpty {
                guard let found = MCPColors.named(asked) else {
                    return answer(.refused(MCPColors.refusal(asked)))
                }
                chosen = found
            }

            let group = store.createGroup(
                name: name,
                icon: icon.isEmpty ? defaultIcon : icon,
                kind: kind)

            let details = context.string("description")?
                .trimmingCharacters(in: .whitespaces)

            if chosen != .none || (details?.isEmpty == false) {
                store.update(group.id) { group in
                    if chosen != .none { group.color = chosen }
                    if let details, !details.isEmpty { group.details = details }
                }
            }

            answer(.json(describe(store.groups.first { $0.id == group.id } ?? group)))
        }
    }

    private static func moveToGroup(
        _ store: SidebarGroupStore,
        _ terminal: @escaping (UUID) -> Terminal?
    ) -> MCPToolHandler {
        MCPToolHandler(
            tool: MCPTool(
                name: "move_to_group",
                description: """
                    File a terminal under a sidebar group, moving it out of whatever \
                    section it is in now. Use it after create_group to put the terminals \
                    you are working in together, or to tidy a stray terminal into a group \
                    that already exists. The terminal keeps running and nothing is typed \
                    into it. Both ids are the ones list_terminals and list_groups hand \
                    out.
                    """,
                schema: MCPSchema.object(
                    [
                        "terminal": MCPSchema.string(
                            "The tab's id, as list_terminals gives it."),
                        "group": MCPSchema.string(
                            "The group's id, as list_groups or create_group gives it."),
                    ],
                    required: ["terminal", "group"])
            )
        ) { context, answer in
            guard let surfaceID = context.surface("terminal") else {
                return answer(.refused(idRefusal(
                    context.string("terminal"),
                    argument: "terminal",
                    from: "list_terminals")))
            }

            guard let group = context.string("group").flatMap(UUID.init(uuidString:)) else {
                return answer(.refused(idRefusal(
                    context.string("group"),
                    argument: "group",
                    from: "list_groups")))
            }

            guard let tab = terminal(surfaceID) else {
                return answer(.refused(
                    "No terminal in Phantom has the id \(surfaceID.uuidString). It has "
                    + "been closed, or it belongs to another build; call list_terminals "
                    + "for the ids that are open now."))
            }

            guard let target = store.groups.first(where: { $0.id == group }) else {
                return answer(.refused(
                    "Phantom has no group with the id \(group.uuidString). Call "
                    + "list_groups for the groups that exist, or create_group to make "
                    + "this one."))
            }

            let name = store.tabOverrides[surfaceID]?.name ?? tab.title
            let label = name.isEmpty ? surfaceID.uuidString : name

            /// Asked of the store rather than of the assignments, because a
            /// project group claims a terminal by its working directory and
            /// leaves no assignment behind to find.
            let current = store.resolveGroup(surfaceId: surfaceID, pwd: tab.pwd)
            guard current?.id != target.id else {
                return answer(.text(
                    "“\(label)” is already in “\(target.name)”. Nothing moved."))
            }

            store.assign(surfaceId: surfaceID, to: target.id)

            answer(.json(.object([
                "terminal": .string(surfaceID.uuidString),
                "group": .string(target.id.uuidString),
                "moved": .string("“\(label)” is now in “\(target.name)”."),
            ])))
        }
    }

    // MARK: What the refusals say

    /// What a group wears when the caller names no icon. The same default the
    /// sidebar's own dialog starts from, so a group made by an agent looks
    /// like one made by hand.
    static let defaultIcon = "folder"

    private static var agents: String {
        CodingAgent.allCases.map(\.rawValue).joined(separator: ", ")
    }

    /// Why an icon cannot be worn, or nil when it can.
    ///
    /// An icon is one string holding one of three things — see `SidebarIconID`
    /// — and only one of them can be wrong in a way that shows: an SF Symbol
    /// name this build cannot draw becomes an empty box on the reader's
    /// sidebar for as long as the group exists. It is checked here rather than
    /// left to the renderer, because the renderer has nobody to tell.
    static func iconRefusal(_ icon: String) -> String? {
        switch SidebarIconID.kind(of: icon) {
        case .empty, .emoji, .agent:
            return nil

        case .unknownAgent:
            return "“\(icon)” names an agent this build does not draw a mark for. "
                + "The agents are: \(agents)."

        case .symbol:
            guard NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil
            else { return nil }
            return "“\(icon)” is not an SF Symbol this system can draw, and it would "
                + "leave an empty square in the sidebar. Use an SF Symbol name, a single "
                + "emoji, or leave the icon out for “\(defaultIcon)”."
        }
    }

    /// What a project-root check settles: the path as it will be stored, or
    /// the sentence saying why it cannot be.
    enum Root {
        case path(String)
        case refused(String)
    }

    /// The project root a caller named, written the way the sidebar writes it.
    ///
    /// Stored with the home directory abbreviated back to `~`, which is what
    /// the reader's own folder picker stores, so the two produce the same row.
    /// `SidebarGroup.claims` expands it again when it matches a terminal.
    static func root(_ path: String) -> Root {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .refused(
                "create_group needs an absolute “project_root” and “\(path)” is "
                + "relative. Send the whole path, from / or ~.")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .refused(
                "There is no folder at \(expanded), so no terminal could ever be "
                + "working inside it. Name a folder that exists, or leave project_root "
                + "out and file terminals with move_to_group.")
        }

        return .path((expanded as NSString).abbreviatingWithTildeInPath)
    }

    /// The sentence for an id that is missing or is not one of ours.
    static func idRefusal(_ given: String?, argument: String, from tool: String) -> String {
        guard let given, !given.isEmpty else {
            return "move_to_group needs a “\(argument)” argument: the id \(tool) "
                + "hands out."
        }
        return "“\(given)” is not an id Phantom hands out for \(argument). They are "
            + "UUIDs; call \(tool) to read the current ones."
    }
}
