import SwiftUI

/// The completion preferences, as the detail half of the Language Servers
/// screen.
///
/// The three globals are `@AppStorage`, which is what makes them live: a
/// change here lands in `UserDefaults` immediately, and every other reader
/// of the same key — including `EditorPaneView`, which folds them into the
/// `CodeEditorConfiguration` handed to the engine — is republished by the
/// same write. The per-language table cannot be, because `@AppStorage` has
/// no dictionary, so those rows go through `CompletionSettingsStore` and
/// tell the screen themselves.
struct CompletionSettingsForm: View {
    /// The contributed languages to list alongside the compiled-in ones.
    ///
    /// Passed in rather than read from `LanguageResolver.shared` here, so
    /// the list is a function of what the parent already resolved and the
    /// two halves of the screen cannot disagree about which extensions
    /// exist.
    let languages: LanguageCatalog

    /// Told to the parent so the sidebar's summary line repaints. Nothing
    /// publishes the per-language blob, and the row above says how many
    /// languages are switched off.
    var onChange: () -> Void = {}

    @AppStorage(CompletionSettingsStore.enabledKey) private var isEnabled = true
    @AppStorage(CompletionSettingsStore.bufferWordsKey) private var usesBufferWords = true
    @AppStorage(CompletionSettingsStore.delayKey)
    private var delayRaw = CompletionDelay.default.rawValue

    /// Bumped by every per-language write, purely to re-run `body`.
    ///
    /// The rows read `CompletionSettingsStore` through a computed `Binding`
    /// rather than through `@AppStorage`, and a plain `UserDefaults` write
    /// publishes nothing — so without this a switch would move under the
    /// pointer and snap back on the next redraw.
    @State private var revision = 0

    private var delay: CompletionDelay { .named(delayRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                Text("Completion")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Form {
                Section {
                    Toggle("Suggest as You Type", isOn: $isEnabled)
                        .toggleStyle(.switch)
                } footer: {
                    Text("Off, nothing opens the list — not a trigger character, not an explicit request. The per-language switches below cannot bring it back; this one is the master.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Ask For Suggestions", selection: $delayRaw) {
                        ForEach(CompletionDelay.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .disabled(!isEnabled)

                    LabeledContent("Delay") {
                        Text(verbatim: delay.detail)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Include Words From the File", isOn: $usesBufferWords)
                        .toggleStyle(.switch)
                        .disabled(!isEnabled)
                } header: {
                    Text("Behaviour")
                } footer: {
                    Text("A pause coalesces a burst of typing into one request instead of one per character. Typing a trigger character — a dot, usually — and asking explicitly both skip it, because each is already a pause.\n\nWords from the file are what still completes when no server is installed for a language; they are ranked below anything a server said.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(rows) { row in
                        Toggle(isOn: binding(for: row.languageID)) {
                            HStack(spacing: 6) {
                                Text(verbatim: row.title)
                                if row.isContributed {
                                    Text("Extension")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            Capsule().fill(Color.secondary.opacity(0.15))
                                        )
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .disabled(!isEnabled)
                    }

                    if hasStoredPreferences {
                        Button("Follow Defaults for All Languages") {
                            CompletionSettingsStore.clearLanguagePreferences()
                            revision += 1
                            onChange()
                        }
                    }
                } header: {
                    Text("Languages")
                } footer: {
                    Text("A language nobody has touched is not stored at all — it follows whatever this build's default is, so the default can change without overwriting a choice you made. Only the languages Phantom can complete for are listed; a file type with no server and no extension behind it follows the master switch above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: isEnabled) { _ in onChange() }
        .onChange(of: usesBufferWords) { _ in onChange() }
        .onChange(of: delayRaw) { _ in onChange() }
    }

    /// Reads the store on every evaluation rather than caching, so a value
    /// written by the button below is the one drawn.
    ///
    /// The getter does not name `revision`, and does not need to: mutating
    /// a `@State` invalidates the view that owns it whether or not the old
    /// value was read, so `body` re-runs, this `Binding` is rebuilt, and
    /// the getter runs again against the store.
    private func binding(for languageID: String) -> Binding<Bool> {
        Binding(
            get: {
                CompletionSettingsStore.preference(forLanguage: languageID)
                    ?? CompletionSettingsStore.languageDefault
            },
            set: { newValue in
                CompletionSettingsStore.setEnabled(newValue, forLanguage: languageID)
                revision += 1
                onChange()
            }
        )
    }

    private var hasStoredPreferences: Bool {
        !CompletionSettingsStore.byLanguage.isEmpty
    }

    // MARK: The list

    /// One row per language id, compiled-in and contributed together,
    /// sorted by the name on screen.
    ///
    /// Deduplicated by language id, with the contributed one losing: a
    /// contribution that claims a language this build already owns loads
    /// shadowed and inert, so listing it twice would offer two switches for
    /// one answer. The registry is consulted for the id and the extension
    /// only for the ones it adds.
    private var rows: [LanguageCompletionRow] {
        var seen: Set<String> = []
        var rows: [LanguageCompletionRow] = []

        for server in LSPServerRegistry.all where seen.insert(server.languageID).inserted {
            rows.append(LanguageCompletionRow(
                languageID: server.languageID,
                title: LanguageCompletionRow.title(forLanguageID: server.languageID),
                isContributed: false
            ))
        }

        for contributed in languages.contributed
        where seen.insert(contributed.language.languageID).inserted {
            rows.append(LanguageCompletionRow(
                languageID: contributed.language.languageID,
                title: contributed.language.displayName,
                isContributed: true
            ))
        }

        return rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

/// One switchable language.
private struct LanguageCompletionRow: Identifiable {
    let languageID: String
    let title: String
    let isContributed: Bool

    var id: String { languageID }

    /// A human name for a compiled-in LSP language id.
    ///
    /// `LSPServerDefinition.displayName` cannot answer this: it is the
    /// *server's* name, and four ids share "TypeScript Language Server" —
    /// a list of those would offer the same row four times with no way to
    /// tell which `.tsx` was. Kept beside the list that needs it rather
    /// than added to the registry, which is a table about servers; a
    /// language with no server at all still belongs in this list one day,
    /// and the registry would have nowhere to put it.
    static func title(forLanguageID languageID: String) -> String {
        let names = [
            "typescript": "TypeScript",
            "typescriptreact": "TypeScript JSX",
            "javascript": "JavaScript",
            "javascriptreact": "JavaScript JSX",
            "vue": "Vue",
            "swift": "Swift",
            "kotlin": "Kotlin",
            "python": "Python",
            "rust": "Rust",
            "go": "Go",
            "zig": "Zig",
            "json": "JSON",
            "yaml": "YAML",
            "shellscript": "Shell",
            "html": "HTML",
            "css": "CSS",
            "scss": "SCSS",
            "less": "Less",
            "java": "Java",
            "c": "C",
            "cpp": "C++",
            "terraform": "Terraform",
            "php": "PHP",
            "ruby": "Ruby",
            "markdown": "Markdown",
        ]
        /// A server added to the registry without a name here is listed
        /// under its id rather than dropped: a missing row is a language
        /// that silently cannot be configured, which is worse than an ugly
        /// one.
        return names[languageID] ?? languageID.capitalized
    }
}
