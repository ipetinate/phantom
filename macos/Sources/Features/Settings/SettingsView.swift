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
        case behaviors
        case keyboardShortcuts
        case languageServers
        case agents
        case worktrees

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .icon: return "Icon"
            case .sidebar: return "Sidebar"
            case .files: return "Files"
            case .behaviors: return "Behaviors"
            case .keyboardShortcuts: return "Keyboard Shortcuts"
            case .languageServers: return "Language Servers"
            case .agents: return "Agents"
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
            case .behaviors: return "slider.horizontal.3"
            case .keyboardShortcuts: return "keyboard"
            case .languageServers: return "chevron.left.forwardslash.chevron.right"
            case .agents: return "sparkles"
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
                IconSettingsView()
            case .sidebar:
                SidebarSettingsView(ghostty: ghostty, store: store)
            case .files:
                FilesSettingsView()
            case .behaviors:
                BehaviorsSettingsView(ghostty: ghostty, store: store)
            case .keyboardShortcuts:
                KeyboardShortcutsSettingsView()
            case .languageServers:
                LanguageServersSettingsView()
            case .agents:
                AgentsSettingsView()
            case .worktrees:
                WorktreesSettingsView()
            }
        }
        .frame(minWidth: 960, minHeight: 600)
    }
}

/// General behavior: access to the raw configuration.
struct GeneralSettingsView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    var body: some View {
        Form {
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
    }
}

/// Sidebar behavior: visibility, ordering and which tab info shows.
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
    @AppStorage("SidebarTabAlwaysShowActions") private var tabAlwaysShowActions = false

    @AppStorage("SidebarGroupShowPullRequests") private var groupShowPullRequests = true
    @AppStorage("SidebarGroupShowClaude") private var groupShowClaude = true
    @AppStorage("SidebarGroupShowNewTerminal") private var groupShowNewTerminal = true
    @AppStorage("SidebarGroupShowWorktree") private var groupShowWorktree = true
    @AppStorage("SidebarGroupShowCount") private var groupShowCount = true
    @AppStorage("SidebarGroupAlwaysShowActions") private var groupAlwaysShowActions = false

    @AppStorage("SidebarChromeShowWorktree") private var chromeShowWorktree = true
    @AppStorage("SidebarChromeAlwaysShowActions") private var chromeAlwaysShowActions = false

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
                Text("The sidebar toggle applies to new windows. Sidebar style (background, width, tab item look) lives in Appearance.")
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
                Text("Panels")
            } footer: {
                Text("Terminals is always available. With everything else off there is nothing to switch between, so the tabs disappear and the sidebar is just the terminal list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show New Terminal in Worktree", isOn: $chromeShowWorktree)
                    .toggleStyle(.switch)
                Toggle("Always Show Toolbar Icons", isOn: $chromeAlwaysShowActions)
                    .toggleStyle(.switch)
            } header: {
                Text("Toolbar")
            } footer: {
                Text("New Terminal, New Claude Session, New Group and Refresh appear on hover by default. The sidebar show/hide button is always visible either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Working Directory", isOn: $showDirectory)
                    .toggleStyle(.switch)
                Toggle("Show Git Branch", isOn: $showGitBranch)
                    .toggleStyle(.switch)
                Toggle("Show Uncommitted Changes", isOn: $showGitStatus)
                    .toggleStyle(.switch)
                Toggle("Show Open Pull Request", isOn: $showPullRequest)
                    .toggleStyle(.switch)
                Toggle("Show Dev Server Port", isOn: $showDevServer)
                    .toggleStyle(.switch)
                Toggle("Show Plan Tag", isOn: $showPlan)
                    .toggleStyle(.switch)
                Toggle("Show Switch Worktree", isOn: $tabShowWorktree)
                    .toggleStyle(.switch)
                Toggle("Always Show Tab Actions", isOn: $tabAlwaysShowActions)
                    .toggleStyle(.switch)
            } header: {
                Text("Tab Info")
            } footer: {
                Text("A tab's agent buttons appear on hover — turn the last one on to keep them visible. Which agents they offer is in Agents. The plan tag only ever shows while the Claude session that wrote the plan is running in that tab. Switch Worktree appears only on a terminal sitting at a prompt, because it types a cd into it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Pull Requests", isOn: $groupShowPullRequests)
                    .toggleStyle(.switch)
                Toggle("Show New Claude Session", isOn: $groupShowClaude)
                    .toggleStyle(.switch)
                Toggle("Show New Terminal", isOn: $groupShowNewTerminal)
                    .toggleStyle(.switch)
                Toggle("Show New Terminal in Worktree", isOn: $groupShowWorktree)
                    .toggleStyle(.switch)
                Toggle("Show Terminal Count", isOn: $groupShowCount)
                    .toggleStyle(.switch)
                Toggle("Always Show Group Actions", isOn: $groupAlwaysShowActions)
                    .toggleStyle(.switch)
            } header: {
                Text("Group")
            } footer: {
                Text("The action icons above appear in a group's header on hover by default — turn this on to keep them visible. The group's icon, name and color are set per group, from its context menu.")
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

/// Behavioral options grouped by area — nothing here changes looks.
struct BehaviorsSettingsView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    @AppStorage("SidebarRestoreAgentSessions") private var restoreAgentSessions = true
    @AppStorage("SidebarNewTabPosition") private var newTabPosition = "end"
    @AppStorage("SidebarNewTabHomeDirectory") private var newTabHomeDirectory = ""
    @AppStorage("AgentNotificationsEnabled") private var agentNotifications = true
    @AppStorage(FileOpenTarget.defaultsKey)
    private var fileOpenTarget = FileOpenTarget.alwaysNewTerminal.rawValue

    @State private var restoreWindows = true

    var body: some View {
        Form {
            Section("General") {
                /// `never`, not `default`.
                ///
                /// The domain is `always` / `default` / `never`, and this
                /// wrote the middle value when switched off — which means
                /// "follow the system", and every reader in the app only
                /// bails on `never`. So turning the switch off restored the
                /// windows anyway. `default` stays reachable from the config
                /// file, which is the boundary this window already declares.
                Toggle("Restore Windows on Launch", isOn: $restoreWindows)
                    .toggleStyle(.switch)
                    .onChange(of: restoreWindows) { value in
                        store.set("window-save-state", value ? "always" : "never")
                        store.apply(ghostty: ghostty)
                    }
            }

            Section {
                Toggle("Resume Agent Sessions on Restore", isOn: $restoreAgentSessions)
                    .toggleStyle(.switch)

                Toggle("Notify on Agent Activity", isOn: $agentNotifications)
                    .toggleStyle(.switch)
            } header: {
                Text("Terminal")
            } footer: {
                Text("When windows are restored, tabs that were running a Claude Code session run `claude --continue` to pick the conversation back up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("New Terminal Position", selection: $newTabPosition) {
                    Text("Bottom of List").tag("end")
                    Text("Top of List").tag("start")
                }

                TextField(
                    "New Terminal Home Directory",
                    text: $newTabHomeDirectory,
                    prompt: Text("~/")
                )
            } header: {
                Text("Sidebar")
            } footer: {
                Text("New terminals and agents created by the sidebar start in the default home directory (`~/`) unless a group's project path applies. Type a path like `~/dev` to change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Opening a File", selection: $fileOpenTarget) {
                    ForEach(FileOpenTarget.allCases) { target in
                        Text(target.title).tag(target.rawValue)
                    }
                }
            } header: {
                Text("Panels")
            } footer: {
                Text("Reuse only applies to a terminal sitting at a prompt. One that's still running something — an editor from the last file, a dev server — always gets a new terminal instead, so a command can never land inside whatever is already open there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Behaviors")
        .onAppear {
            restoreWindows = (store.string("window-save-state") ?? "always") == "always"
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
    @State private var feedback: String?

    @AppStorage("SidebarShowClaude") private var sidebarShowClaude = true
    @AppStorage("SidebarShowCodex") private var sidebarShowCodex = true
    @AppStorage("SidebarGroupShowClaude") private var groupShowClaude = true
    @AppStorage("SidebarGroupShowCodex") private var groupShowCodex = true
    @AppStorage("SidebarShowOpenCode") private var sidebarShowOpenCode = true
    @AppStorage("SidebarGroupShowOpenCode") private var groupShowOpenCode = true
    @AppStorage("SidebarTabShowClaude") private var tabShowClaude = true
    @AppStorage("SidebarTabShowCodex") private var tabShowCodex = true
    @AppStorage("SidebarTabShowOpenCode") private var tabShowOpenCode = true

    var body: some View {
        Form {
            Section("Sidebar") {
                Toggle(isOn: $sidebarShowClaude) {
                    HStack(spacing: 6) { ClaudeIcon(size: 14, tint: .original); Text("Claude Code") }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $sidebarShowCodex) {
                    HStack(spacing: 6) { CodexIcon(size: 14, originalColors: true); Text("Codex") }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $sidebarShowOpenCode) {
                    HStack(spacing: 6) { OpenCodeIcon(size: 14, originalColors: true); Text("OpenCode") }
                }
                .toggleStyle(.switch)
            }

            Section {
                Toggle(isOn: $groupShowClaude) {
                    HStack(spacing: 6) { ClaudeIcon(size: 14, tint: .original); Text("Claude Code") }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $groupShowCodex) {
                    HStack(spacing: 6) { CodexIcon(size: 14, originalColors: true); Text("Codex") }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $groupShowOpenCode) {
                    HStack(spacing: 6) { OpenCodeIcon(size: 14, originalColors: true); Text("OpenCode") }
                }
                .toggleStyle(.switch)
            } header: {
                Text("Groups")
            } footer: {
                Text("Control the new-agent buttons independently in the main sidebar and in each group header.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $tabShowClaude) {
                    HStack(spacing: 6) { ClaudeIcon(size: 14, tint: .original); Text("Claude Code") }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $tabShowCodex) {
                    HStack(spacing: 6) { CodexIcon(size: 14, originalColors: true); Text("Codex") }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $tabShowOpenCode) {
                    HStack(spacing: 6) { OpenCodeIcon(size: 14, originalColors: true); Text("OpenCode") }
                }
                .toggleStyle(.switch)
            } header: {
                Text("Tabs")
            } footer: {
                Text("These start the agent in the tab you hovered, rather than in a new one — so they are hidden while that tab already has a session running, where the command would land in the agent's prompt as a question instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                if let feedback { Text(feedback).font(.caption).foregroundStyle(feedback.contains("failed") ? .red : .secondary) }
            } header: {
                Text("Hooks")
            } footer: {
                Text("Installs Phantom hooks for each agent while preserving existing configuration. Hooks update the tab activity indicator when an agent is working, waiting, or done.")
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
