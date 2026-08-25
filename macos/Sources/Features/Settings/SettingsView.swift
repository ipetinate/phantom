import SwiftUI

/// Root of the settings window: section list on the left, the selected
/// section's form on the right. Appearance owns every style control;
/// the other sections hold behavior only.
struct SettingsRootView: View {
    let ghostty: Ghostty.App

    @ObservedObject private var store = GuiConfigStore.shared

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general
        case appearance
        case icon
        case sidebar
        case files
        case keyboardShortcuts
        case languageServers
        case agents
        case mcp
        case worktrees

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .icon: return "Icon"
            case .sidebar: return "Sidebar"
            case .files: return "Editor"
            case .keyboardShortcuts: return "Keyboard Shortcuts"
            case .languageServers: return "Languages"
            case .agents: return "Agents"
            case .mcp: return "MCP"
            case .worktrees: return "Worktrees"
            }
        }

        /// SF Symbol, or nil for a pane that ships its own artwork — the
        /// same shape `SidebarPane.symbol` uses, and for the same reason: the
        /// worktrees mark is this app's own drawing, not one of Apple's.
        var icon: String? {
            switch self {
            case .worktrees: return nil
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            case .icon: return "app.badge"
            case .sidebar: return "sidebar.left"
            case .files: return "doc.text"
            case .keyboardShortcuts: return "keyboard"
            case .languageServers: return "chevron.left.forwardslash.chevron.right"
            case .agents: return "sparkles"
            case .mcp: return "point.3.connected.trianglepath.dotted"
            }
        }
    }

    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    if let symbol = section.icon {
                        Image(systemName: symbol)
                    } else {
                        WorktreeIcon(size: 13)
                    }
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            // Wide enough for the longest section name at the window's
            // opening width. "Keyboard Shortcuts" is the longest, and at an
            // ideal of 180 it opened already truncated to "Keyboard
            // Shortc…" — a settings list that hides what it is offering
            // before you have touched anything.
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            switch selection {
            case .general:
                GeneralSettingsView(ghostty: ghostty, store: store)
            case .appearance:
                AppearanceSettingsView(ghostty: ghostty, store: store)
            case .icon:
                AppIconPickerView()
            case .sidebar:
                SidebarSettingsView(ghostty: ghostty, store: store)
            case .files:
                FilesSettingsView()
            case .keyboardShortcuts:
                KeyboardShortcutsSettingsView()
            case .languageServers:
                LanguageServersSettingsView()
            case .agents:
                AgentsSettingsView()
            case .mcp:
                MCPSettingsView()
            case .worktrees:
                WorktreesSettingsView()
            }
        }
    }
}

/// General behavior: access to the raw configuration.
struct GeneralSettingsView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    @AppStorage("SidebarRestoreAgentSessions") private var restoreAgentSessions = true

    @State private var restoreWindows = true

    var body: some View {
        Form {
            Section {
                /// `never`, not `default`.
                ///
                /// The domain is `always` / `default` / `never`, and this
                /// wrote the middle value when switched off — "follow the
                /// system" — while every reader in the app only bails on
                /// `never`. So turning the switch off restored the windows
                /// anyway. `default` stays reachable from the config file,
                /// which is the boundary this window already declares.
                Toggle("Restore Windows on Launch", isOn: $restoreWindows)
                    .toggleStyle(.switch)
                    .onChange(of: restoreWindows) { value in
                        store.set("window-save-state", value ? "always" : "never")
                        store.apply(ghostty: ghostty)
                    }

                /// Disabled with its parent, and next to it. It used to sit
                /// two panes away from the switch that decides whether it
                /// can happen at all.
                Toggle("Resume Agent Sessions on Restore", isOn: $restoreAgentSessions)
                    .toggleStyle(.switch)
                    .disabled(!restoreWindows)
            } header: {
                Text("On Launch")
            } footer: {
                Text("Restored tabs that were running a Claude Code session run `claude --continue` to pick the conversation back up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Phantom Settings File") {
                    Button("Open in Editor") {
                        NSWorkspace.shared.open(store.guiFileURL)
                    }
                }

                LabeledContent("Main Config File") {
                    Button("Open in Editor") {
                        ghostty.openConfig()
                    }
                }
            } footer: {
                Text("Everything changed in this window is stored in \(GuiConfigStore.fileName) (the Phantom settings file), which is included from your main config. Hand-written options in the main config stay untouched. Style options (fonts, colors, blur) live in Appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear {
            restoreWindows = (store.string("window-save-state") ?? "always") == "always"
        }
    }
}

/// Where the sidebar's parts are, and which of them show.
///
/// Grouped by **surface** — toolbar, terminal rows, group headers — because
/// that is how a reader arrives: they are looking at a row and want something
/// off it. Before this the agent buttons lived in another pane entirely, so
/// no surface could be seen whole.
///
/// Four or more show/hide items on one surface fold into a single row; see
/// `SettingsMultiSelect` for why, and for the reaction that prompted it.
struct SidebarSettingsView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    @State private var sidebarEnabled: Bool = false

    @AppStorage("SidebarShowFilesPane") private var showFilesPane = true
    @AppStorage("SidebarShowGitPane") private var showGitPane = true
    @AppStorage("SidebarShowWorktreesPane") private var showWorktreesPane = true

    @AppStorage("SidebarShowDirectory") private var showDirectory = true
    @AppStorage("SidebarShowGitBranch") private var showGitBranch = true
    @AppStorage("SidebarShowGitStatus") private var showGitStatus = true
    @AppStorage("SidebarShowPullRequest") private var showPullRequest = true
    @AppStorage("SidebarShowDevServer") private var showDevServer = true
    @AppStorage("SidebarShowPlan") private var showPlan = true
    @AppStorage("SidebarTabShowWorktree") private var tabShowWorktree = true
    @AppStorage("SidebarTabShowClaude") private var tabShowClaude = AgentButtonDefaults.isShown(.claude)
    @AppStorage("SidebarTabShowCodex") private var tabShowCodex = AgentButtonDefaults.isShown(.codex)
    @AppStorage("SidebarTabShowOpenCode") private var tabShowOpenCode = AgentButtonDefaults.isShown(.opencode)
    @AppStorage("SidebarTabShowAntigravity") private var tabShowAntigravity = AgentButtonDefaults.isShown(.antigravity)
    @AppStorage("SidebarTabAlwaysShowActions") private var tabAlwaysShowActions = false

    @AppStorage("SidebarGroupShowPullRequests") private var groupShowPullRequests = true
    @AppStorage("SidebarGroupShowClaude") private var groupShowClaude = AgentButtonDefaults.isShown(.claude)
    @AppStorage("SidebarGroupShowCodex") private var groupShowCodex = AgentButtonDefaults.isShown(.codex)
    @AppStorage("SidebarGroupShowOpenCode") private var groupShowOpenCode = AgentButtonDefaults.isShown(.opencode)
    @AppStorage("SidebarGroupShowAntigravity") private var groupShowAntigravity = AgentButtonDefaults.isShown(.antigravity)
    @AppStorage("SidebarGroupShowNewTerminal") private var groupShowNewTerminal = true
    @AppStorage("SidebarGroupShowWorktree") private var groupShowWorktree = true
    @AppStorage("SidebarGroupShowCount") private var groupShowCount = true
    @AppStorage("SidebarGroupAlwaysShowActions") private var groupAlwaysShowActions = false

    @AppStorage("SidebarChromeShowWorktree") private var chromeShowWorktree = true
    @AppStorage("SidebarShowClaude") private var chromeShowClaude = AgentButtonDefaults.isShown(.claude)
    @AppStorage("SidebarShowCodex") private var chromeShowCodex = AgentButtonDefaults.isShown(.codex)
    @AppStorage("SidebarShowOpenCode") private var chromeShowOpenCode = AgentButtonDefaults.isShown(.opencode)
    @AppStorage("SidebarShowAntigravity") private var chromeShowAntigravity = AgentButtonDefaults.isShown(.antigravity)
    @AppStorage("SidebarChromeAlwaysShowActions") private var chromeAlwaysShowActions = false

    @AppStorage("SidebarNewTabPosition") private var newTabPosition = "end"
    @AppStorage("SidebarNewTabHomeDirectory") private var newTabHomeDirectory = ""

    var body: some View {
        Form {
            Section {
                Toggle("Show Sidebar", isOn: $sidebarEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: sidebarEnabled) { value in
                        store.set("sidebar", value ? "true" : "false")
                        store.apply(ghostty: ghostty)
                    }
            } footer: {
                Text("Applies to new windows. How the sidebar looks — background, width, tab item style — is in Appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("File Explorer", isOn: $showFilesPane)
                    .toggleStyle(.switch)
                Toggle("Git", isOn: $showGitPane)
                    .toggleStyle(.switch)
                Toggle("Worktrees", isOn: $showWorktreesPane)
                    .toggleStyle(.switch)
            } header: {
                Text("Panes")
            } footer: {
                Text("Terminals is always available. With everything else off there is nothing to switch between, so the tabs disappear and the sidebar is just the terminal list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            FileExplorerSettingsSection()

            Section {
                SettingsMultiSelect(
                    title: "Buttons",
                    options: [
                        .init(id: "worktree", title: "New Terminal in Worktree",
                              short: "Worktree", isOn: $chromeShowWorktree),
                        .init(id: "claude", title: "Claude Code",
                              short: "Claude", isOn: $chromeShowClaude),
                        .init(id: "codex", title: "Codex", isOn: $chromeShowCodex),
                        .init(id: "opencode", title: "OpenCode", isOn: $chromeShowOpenCode),
                        .init(id: "antigravity", title: "Antigravity",
                              isOn: $chromeShowAntigravity),
                    ],
                    emptyLabel: "Hidden")

                Toggle("Always Show Buttons", isOn: $chromeAlwaysShowActions)
                    .toggleStyle(.switch)
            } header: {
                Text("Toolbar")
            } footer: {
                Text("New Terminal, New Group and Refresh are always offered and are not listed here. Buttons appear on hover unless you keep them visible; the sidebar show/hide button is visible either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SettingsMultiSelect(
                    title: "Information",
                    options: [
                        .init(id: "directory", title: "Working Directory",
                              short: "Directory", isOn: $showDirectory),
                        .init(id: "branch", title: "Git Branch",
                              short: "Branch", isOn: $showGitBranch),
                        .init(id: "status", title: "Uncommitted Changes",
                              short: "Changes", isOn: $showGitStatus),
                        .init(id: "pr", title: "Open Pull Request",
                              short: "Pull Request", isOn: $showPullRequest),
                        .init(id: "devserver", title: "Dev Server Port",
                              short: "Dev Server", isOn: $showDevServer),
                        .init(id: "plan", title: "Plan Tag", short: "Plan", isOn: $showPlan),
                    ])

                SettingsMultiSelect(
                    title: "Buttons",
                    options: [
                        .init(id: "worktree", title: "Switch Worktree",
                              short: "Worktree", isOn: $tabShowWorktree),
                        .init(id: "claude", title: "Claude Code",
                              short: "Claude", isOn: $tabShowClaude),
                        .init(id: "codex", title: "Codex", isOn: $tabShowCodex),
                        .init(id: "opencode", title: "OpenCode", isOn: $tabShowOpenCode),
                        .init(id: "antigravity", title: "Antigravity",
                              isOn: $tabShowAntigravity),
                    ],
                    emptyLabel: "Hidden")

                Toggle("Always Show Buttons", isOn: $tabAlwaysShowActions)
                    .toggleStyle(.switch)
            } header: {
                Text("Terminal Rows")
            } footer: {
                Text("The plan tag shows only while the Claude session that wrote the plan is running in that row. Switch Worktree appears only on a terminal sitting at a prompt, because it types a cd into it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SettingsMultiSelect(
                    title: "Buttons",
                    options: [
                        .init(id: "prs", title: "Pull Requests", isOn: $groupShowPullRequests),
                        .init(id: "newterminal", title: "New Terminal",
                              short: "Terminal", isOn: $groupShowNewTerminal),
                        .init(id: "worktree", title: "New Terminal in Worktree",
                              short: "Worktree", isOn: $groupShowWorktree),
                        .init(id: "claude", title: "Claude Code",
                              short: "Claude", isOn: $groupShowClaude),
                        .init(id: "codex", title: "Codex", isOn: $groupShowCodex),
                        .init(id: "opencode", title: "OpenCode", isOn: $groupShowOpenCode),
                        .init(id: "antigravity", title: "Antigravity",
                              isOn: $groupShowAntigravity),
                    ],
                    emptyLabel: "Hidden")

                Toggle("Show Terminal Count", isOn: $groupShowCount)
                    .toggleStyle(.switch)
                Toggle("Always Show Buttons", isOn: $groupAlwaysShowActions)
                    .toggleStyle(.switch)
            } header: {
                Text("Group Headers")
            } footer: {
                Text("A group's own icon, name and color are set from its context menu in the sidebar, not here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Position", selection: $newTabPosition) {
                    Text("Bottom of List").tag("end")
                    Text("Top of List").tag("start")
                }
                .pickerStyle(.segmented)

                TextField("Home Directory", text: $newTabHomeDirectory, prompt: Text("~/"))
            } header: {
                Text("New Terminals")
            } footer: {
                Text("Terminals the sidebar opens start in the home directory unless a group's project path applies. Type a path like `~/dev` to change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sidebar")
        .onAppear {
            sidebarEnabled = store.bool("sidebar")
        }
    }
}

/// Integration with AI coding agents: installs the terminal-side hooks
/// that surface agent activity in the sidebar. Claude Code today; more
/// agents later.
struct AgentsSettingsView: View {
    @State private var claudeInstalled = ClaudeHooksInstaller.isInstalled
    @State private var codexInstalled = CodexHooksInstaller.isInstalled
    @State private var openCodeInstalled = OpenCodeHooksInstaller.isInstalled
    @State private var antigravityInstalled = AntigravityHooksInstaller.isInstalled
    @State private var feedback: String?

    @AppStorage("AgentNotificationsEnabled") private var agentNotifications = true

    var body: some View {
        Form {
            Section {
                agentHookRow(
                    title: "Claude Code",
                    icon: AnyView(ClaudeIcon(size: 14, tint: .original)),
                    installed: claudeInstalled,
                    install: {
                        let ok = ClaudeHooksInstaller.install()
                        claudeInstalled = ClaudeHooksInstaller.isInstalled
                        feedback = ok && claudeInstalled ? "Claude hooks installed ✓" : "Claude install failed: \(ClaudeHooksInstaller.lastError ?? "status did not update")"
                    },
                    uninstall: {
                        let ok = ClaudeHooksInstaller.uninstall()
                        claudeInstalled = ClaudeHooksInstaller.isInstalled
                        feedback = ok && !claudeInstalled ? "Claude hooks removed" : "Claude removal failed"
                    }
                )
                agentHookRow(
                    title: "Codex",
                    icon: AnyView(CodexIcon(size: 14, originalColors: true)),
                    installed: codexInstalled,
                    install: {
                        let ok = CodexHooksInstaller.install()
                        codexInstalled = CodexHooksInstaller.isInstalled
                        feedback = ok && codexInstalled ? "Codex hooks installed ✓" : "Codex install failed: \(CodexHooksInstaller.lastError ?? "status did not update")"
                    },
                    uninstall: {
                        let ok = CodexHooksInstaller.uninstall()
                        codexInstalled = CodexHooksInstaller.isInstalled
                        feedback = ok && !codexInstalled ? "Codex hooks removed" : "Codex removal failed"
                    }
                )
                agentHookRow(
                    title: "OpenCode",
                    icon: AnyView(OpenCodeIcon(size: 14, originalColors: true)),
                    installed: openCodeInstalled,
                    install: {
                        openCodeInstalled = OpenCodeHooksInstaller.install()
                        feedback = openCodeInstalled ? "OpenCode hooks installed ✓" : "OpenCode install failed"
                    },
                    uninstall: {
                        openCodeInstalled = !OpenCodeHooksInstaller.uninstall()
                        feedback = openCodeInstalled ? "OpenCode removal failed" : "OpenCode hooks removed"
                    }
                )
                agentHookRow(
                    title: "Antigravity",
                    icon: AnyView(AntigravityIcon(size: 14, tint: .original)),
                    installed: antigravityInstalled,
                    install: {
                        let ok = AntigravityHooksInstaller.install()
                        antigravityInstalled = AntigravityHooksInstaller.isInstalled
                        feedback = ok && antigravityInstalled ? "Antigravity hooks installed ✓" : "Antigravity install failed: \(AntigravityHooksInstaller.lastError ?? "status did not update")"
                    },
                    uninstall: {
                        let ok = AntigravityHooksInstaller.uninstall()
                        antigravityInstalled = AntigravityHooksInstaller.isInstalled
                        feedback = ok && !antigravityInstalled ? "Antigravity hooks removed" : "Antigravity removal failed"
                    }
                )
                if let feedback { Text(feedback).font(.caption).foregroundStyle(feedback.contains("failed") ? .red : .secondary) }
            } header: {
                Text("Hooks")
            } footer: {
                Text("Installs Phantom hooks for each agent while preserving existing configuration. Hooks update the tab activity indicator when an agent is working, waiting, or done. Antigravity reports only working and done: its hook system has no event for a permission prompt that Phantom can answer without also approving the tool call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify on Agent Activity", isOn: $agentNotifications)
                    .toggleStyle(.switch)
            } header: {
                Text("Notifications")
            } footer: {
                Text("A notification when an agent finishes or needs an answer, for the times its window is not the one you are looking at.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Agents")
        .onAppear {
            ClaudeHooksInstaller.logStatus()
            claudeInstalled = ClaudeHooksInstaller.isInstalled
            codexInstalled = CodexHooksInstaller.isInstalled
            openCodeInstalled = OpenCodeHooksInstaller.isInstalled
            antigravityInstalled = AntigravityHooksInstaller.isInstalled
        }
        // Claude Code owns this settings file too and rewrites it when its
        // own settings change, which can drop our registrations. Recheck on
        // every activation so the buttons never describe a stale state.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            claudeInstalled = ClaudeHooksInstaller.isInstalled
            codexInstalled = CodexHooksInstaller.isInstalled
            openCodeInstalled = OpenCodeHooksInstaller.isInstalled
            antigravityInstalled = AntigravityHooksInstaller.isInstalled
        }
    }

    private func agentHookRow(
        title: String,
        icon: AnyView,
        installed: Bool,
        install: @escaping () -> Void,
        uninstall: @escaping () -> Void
    ) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Circle().fill(installed ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(installed ? "Hooks installed" : "Not installed").font(.caption).foregroundStyle(.secondary)
                }
                Button(installed ? "Uninstall" : "Install") { installed ? uninstall() : install() }
            }
        } label: {
            HStack(spacing: 6) { icon; Text(title) }
        }
    }
}
