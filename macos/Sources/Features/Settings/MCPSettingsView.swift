import AppKit
import SwiftUI

/// What a grant reads as, once it is a row in a list rather than an answer to
/// a question.
///
/// The sheet asks "how far should this reach"; the list has to say how far one
/// already does, months later, to somebody who does not remember answering. So
/// the words are different from `MCPPermission.Scope`'s and from the sheet's
/// segment titles on purpose: "This Tab" is a choice, "In “build”" is a fact.
///
/// Pure, and takes the names already resolved, so every sentence here can be
/// asserted without a window.
enum MCPGrantPhrase {
    static func capability(_ capability: MCPPermission.Capability) -> String {
        switch capability {
        case .read: return "Read scrollback"
        case .run: return "Run commands"

        /// Named for what it touches rather than for the capability, because
        /// this list is read months later: "Configure" alone would leave the
        /// reader guessing what they once allowed to be configured.
        case .configure: return "Change language server startup"
        }
    }

    /// How far the grant reaches, naming the tab or group it was anchored to.
    ///
    /// A missing name is said out loud rather than hidden. A `tab` grant whose
    /// surface is gone still matches nothing and still sits in the list, and a
    /// row that quietly read "In one terminal" would leave the reader unable to
    /// tell which of four identical rows is the dead one.
    static func reach(_ grant: MCPPermission.Grant, tab: String?, group: String?) -> String {
        switch grant.scope {
        case .all:
            return "In every terminal"

        case .group:
            guard let group else { return "In a group that is no longer recorded" }
            return "In every terminal in \u{201C}\(group)\u{201D}"

        case .tab:
            guard let tab else { return "In a terminal that is no longer open" }
            return "In \u{201C}\(tab)\u{201D}"
        }
    }
}

/// Puts a name to the ids a grant was written with.
///
/// A grant records a surface UUID and a group as the tools spelled it, because
/// those are what `MCPPermission.isAllowed` compares. Neither is a name, and
/// the reader never saw either.
@MainActor
enum MCPGrantNaming {
    /// What the reader calls this terminal: their own name for it first, then
    /// the title the tab is showing, then nothing.
    ///
    /// The window walk is the same one `TabStateCenter.tabInfo` does, and for
    /// the same reason — a surface belongs to exactly one window and there is
    /// no app-wide index of them.
    static func tab(_ surface: UUID) -> String? {
        if let named = SidebarGroupStore.shared.tabOverrides[surface]?.name,
           !named.isEmpty {
            return named
        }

        for window in NSApp.windows {
            guard let controller = window.windowController as? TerminalController,
                  let model = controller.sidebarTabManager?.models
                      .first(where: { $0.surfaceId == surface })
            else { continue }
            return model.title.isEmpty ? nil : model.title
        }

        return nil
    }

    /// What the reader calls this group.
    ///
    /// Resolved three ways, and deliberately tolerant: the grant's group is a
    /// plain string written by whichever tool raised the question, and the
    /// permission model never says whether that is an id or a name — it only
    /// compares it to itself. Trying the id, then the name, then handing the
    /// string back unchanged means this row stays truthful whichever the tools
    /// settled on, and says something rather than nothing if they later change
    /// their minds.
    static func group(_ group: String) -> String {
        let groups = SidebarGroupStore.shared.groups

        if let byID = groups.first(where: { $0.id.uuidString == group }) {
            return byID.name
        }
        if let byName = groups.first(where: {
            $0.name.compare(group, options: .caseInsensitive) == .orderedSame
        }) {
            return byName.name
        }
        return group
    }
}

/// The MCP pane: whether the server is up, which agents know about it, and
/// what the reader has already allowed an agent to do.
///
/// Three sections in the order a problem is diagnosed in. Is it listening; can
/// the agent find it; what is it allowed to do.
struct MCPSettingsView: View {
    @ObservedObject private var permissions = MCPPermissionStore.shared

    @State private var socket: URL? = MCPServer.shared.socketURL
    @State private var registrations = MCPServerRegistration.status()
    @State private var feedback: String?

    var body: some View {
        Form {
            serverSection
            registrationSection
            grantsSection
        }
        .formStyle(.grouped)
        .navigationTitle("MCP")
        .onAppear(perform: refresh)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in refresh() }
    }

    private func refresh() {
        socket = MCPServer.shared.socketURL
        registrations = MCPServerRegistration.status()
    }

    // MARK: Server

    @ViewBuilder
    private var serverSection: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 4) {
                    Circle()
                        .fill(socket == nil ? Color.secondary : Color.green)
                        .frame(width: 7, height: 7)
                    Text(socket == nil ? "Not listening" : "Listening")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let socket {
                socketRow(socket)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Agents running inside Phantom's terminals reach the app over this socket. It is named after the build, so a debug Phantom and a release one never answer for each other.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The path, spelled out and copyable.
    ///
    /// Not decoration: somebody whose agent cannot see Phantom is looking at
    /// their agent's configuration, and the only way to tell a stale entry from
    /// a current one is to compare the path in it against this.
    private func socketRow(_ url: URL) -> some View {
        LabeledContent("Socket") {
            HStack(spacing: 8) {
                Text(verbatim: url.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.head)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
        }
    }

    // MARK: Registration

    @ViewBuilder
    private var registrationSection: some View {
        Section {
            ForEach(MCPServerRegistration.agents, id: \.id) { agent in
                registrationRow(agent)
            }
            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(feedback.contains("failed") ? .red : .secondary)
            }
        } header: {
            Text("Agents")
        } footer: {
            Text(MCPServerRegistration.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func registrationRow(_ agent: MCPServerRegistration.Agent) -> some View {
        let registered = registrations[agent.id] ?? false

        return LabeledContent {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(registered ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(registered ? "Registered" : "Not registered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(registered ? "Remove" : "Register") {
                    apply(agent, removing: registered)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Self.icon(for: agent.id)
                Text(agent.name)
            }
        }
    }

    /// The same marks the hooks pane uses, so an agent is recognisable in both
    /// places without reading the label.
    private static func icon(for agent: CodingAgent) -> some View {
        AgentBrandMark(agent: agent, size: 14)
    }

    private func apply(_ agent: MCPServerRegistration.Agent, removing: Bool) {
        let worked = removing ? agent.remove() : agent.register()
        registrations = MCPServerRegistration.status()
        let now = registrations[agent.id] ?? false
        let detail = agent.lastError().map { " \u{2014} \($0)" } ?? ""

        if removing {
            feedback = worked && !now
                ? "\(agent.name): removed"
                : "\(agent.name): removal failed\(detail)"
        } else {
            feedback = worked && now
                ? "\(agent.name): registered \u{2713}"
                : "\(agent.name): registration failed\(detail)"
        }
    }

    // MARK: Grants

    @ViewBuilder
    private var grantsSection: some View {
        Section {
            if permissions.grants.isEmpty {
                Text("Nothing allowed yet. Phantom asks the first time an agent reaches for a terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(permissions.grants.enumerated()), id: \.offset) { _, grant in
                    grantRow(grant)
                }
                Button("Revoke All", role: .destructive) {
                    permissions.revokeAll()
                }
            }
        } header: {
            Text("Allowed")
        } footer: {
            Text("Only what you answered \u{201C}Always Allow\u{201D} to. Anything allowed once is forgotten when the agent's connection closes, and is never written down.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func grantRow(_ grant: MCPPermission.Grant) -> some View {
        let tab = grant.surface.flatMap(MCPGrantNaming.tab)
        let group = grant.group.map(MCPGrantNaming.group)

        return LabeledContent {
            Button("Revoke") { permissions.revoke(grant) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPGrantPhrase.capability(grant.capability))
                Text(MCPGrantPhrase.reach(grant, tab: tab, group: group))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
