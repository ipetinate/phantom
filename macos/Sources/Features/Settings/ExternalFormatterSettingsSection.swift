import SwiftUI

/// The formatters that are a command, as a section of the Editor pane.
///
/// One row per `ExternalFormatterRegistry.all`, built from the table rather
/// than written out again here: a fifth tool added there arrives here with
/// nothing to change. A formatter an installed extension contributes gets the
/// same row after them, marked with where it came from.
///
/// Every row says three things, because between them they are the whole
/// question somebody in this pane has. What runs — the command line, spelled
/// as it will be run. Whether it is *there* — a tool that is not installed is
/// the ordinary reason formatting does nothing, and it is invisible until
/// somebody says so. And what it will do that might surprise, for the two that
/// have an answer.
struct ExternalFormatterSettingsSection: View {
    /// Where each tool was found, once the probe has answered. A missing entry
    /// after `hasProbed` means the tool is not installed.
    @State private var paths: [String: String] = [:]
    @State private var hasProbed = false

    /// The reader's own settings, held here rather than read in `body`:
    /// `UserDefaults` is decoded from JSON on every read of the store, and
    /// `body` runs far more often than a switch moves.
    @State private var settings: [String: ExternalFormatterSetting] = [:]

    /// The row whose command and arguments are open for editing. One at a
    /// time — this is a settings list, not a form of forms.
    @State private var editing: String?

    @ObservedObject private var resolver: LanguageResolver = .shared

    private var formatters: [ExternalFormatter] {
        ExternalFormatterRegistry.all + resolver.catalog.formatters.compactMap(\.externalFormatter)
    }

    var body: some View {
        Section {
            ForEach(formatters) { formatter in
                row(formatter)
            }
        } header: {
            Text("Formatters")
        } footer: {
            Text("""
            These run the tools their languages actually use, for the files \
            neither Prettier nor a language server formats. Each one takes the \
            buffer on standard input and hands back the formatted text, and \
            each is given the file's name so it can find the project's own \
            configuration — a `pyproject.toml`, a `stylua.toml`.

            A language server that formats gets there first, so this never \
            overrides what a project's own tooling would do. They run on ⇧⌘F, \
            and on save when Format on Save is on.

            Point one at a different binary — a `ruff` inside a virtualenv, \
            say — by typing its full path. Clearing a field puts the default \
            back.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await probe() }
        .onAppear { settings = ExternalFormatterStore.all }
    }

    // MARK: One formatter

    @ViewBuilder
    private func row(_ formatter: ExternalFormatter) -> some View {
        let setting = settings[formatter.id] ?? ExternalFormatterSetting()
        let effective = ExternalFormatterStore.effective(formatter, setting: setting) ?? formatter

        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: enabled(formatter.id)) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: formatter.languageName)
                        Text(verbatim: formatter.displayName)
                            .foregroundStyle(.secondary)
                        if let provenance = formatter.provenance {
                            Image(systemName: "puzzlepiece")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Contributed by the extension \(provenance.extensionID)")
                        }
                        state(effective.command)
                    }

                    Text(verbatim: effective.invocation)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if let note = formatter.note {
                        Text(verbatim: note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !isInstalled(effective.command) && hasProbed {
                        Text(verbatim: formatter.installHint)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 10) {
                Button(editing == formatter.id ? "Done" : "Configure…") {
                    editing = editing == formatter.id ? nil : formatter.id
                }
                .buttonStyle(.link)
                .font(.caption)

                if !setting.isDefault {
                    Button("Reset") {
                        update(formatter.id) { $0 = ExternalFormatterSetting() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if editing == formatter.id {
                fields(formatter)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func fields(_ formatter: ExternalFormatter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                "Command",
                text: text(formatter.id, \.command),
                prompt: Text(verbatim: formatter.command))

            TextField(
                "Arguments",
                text: text(formatter.id, \.arguments),
                prompt: Text(verbatim: formatter.arguments.joined(separator: " ")))

            Text("""
            \(ExternalFormatter.filePlaceholder) is replaced with the path of \
            the file being formatted. Arguments are split on spaces and not \
            put through a shell.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textFieldStyle(.roundedBorder)
        .padding(.leading, 2)
    }

    /// Installed or not, in three words, and nothing at all until the probe
    /// has answered — "Not installed" guessed before looking is the one
    /// message that sends somebody to reinstall what they already have.
    @ViewBuilder
    private func state(_ command: String) -> some View {
        if !hasProbed {
            EmptyView()
        } else if let path = paths[command] {
            Text("Installed")
                .font(.caption)
                .foregroundStyle(.green)
                .help(path)
        } else {
            Text("Not installed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func isInstalled(_ command: String) -> Bool {
        paths[command] != nil
    }

    // MARK: Reading and writing

    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings[id]?.isEnabled ?? true },
            set: { value in update(id) { $0.isEnabled = value } })
    }

    private func text(
        _ id: String,
        _ field: WritableKeyPath<ExternalFormatterSetting, String>
    ) -> Binding<String> {
        Binding(
            get: { settings[id]?[keyPath: field] ?? "" },
            set: { value in update(id) { $0[keyPath: field] = value } })
    }

    private func update(_ id: String, _ change: (inout ExternalFormatterSetting) -> Void) {
        var setting = settings[id] ?? ExternalFormatterSetting()
        change(&setting)
        ExternalFormatterStore.set(setting, for: id)
        settings = ExternalFormatterStore.all

        /// A command that just changed is a different binary to look for.
        Task { await probe() }
    }

    /// Where each tool is, resolved off the main actor.
    ///
    /// Resolving the login shell's `PATH` costs a shell the first time it is
    /// asked, and this list would otherwise ask for it once per row while
    /// drawing the window — the same mistake `LSPCenter.installedCommands`
    /// exists to have stopped making.
    private func probe() async {
        let commands = formatters.map { formatter -> String in
            let setting = ExternalFormatterStore.setting(for: formatter.id)
            let override = setting.command.trimmingCharacters(in: .whitespaces)
            return override.isEmpty ? formatter.command : override
        }

        let found = await Task.detached(priority: .userInitiated) { () -> [String: String] in
            let searchPath = LoginEnvironment.executableSearchPath()
            var resolved: [String: String] = [:]
            for command in Set(commands) {
                if let path = ExternalFormatterRunner.locate(command, searchPath: searchPath) {
                    resolved[command] = path
                }
            }
            return resolved
        }.value

        paths = found
        hasProbed = true
    }
}
