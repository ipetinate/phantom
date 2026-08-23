import SwiftUI

/// The completion preferences, as one section of the Editor pane.
///
/// A `View` whose body is a `Section` rather than a screen of its own.
/// This used to be the detail half of the Language Servers list, reached
/// through an entry that showed itself only when the search text matched
/// one of four hardcoded words — a settings screen you had to already
/// know about in order to find. It belongs with the rest of the editor's
/// settings, and it leaves the Language Servers list about servers again.
///
/// The three globals are `@AppStorage`, which is what makes them live: a
/// change here lands in `UserDefaults` immediately, and every other reader
/// of the same key — including `EditorPaneView`, which folds them into the
/// `CodeEditorConfiguration` handed to the engine — is republished by the
/// same write. The per-language table cannot be, because `@AppStorage` has
/// no dictionary, so those rows go through `CompletionSettingsStore` and
/// tell the screen themselves.
struct CompletionSettingsSection: View {
    /// Read here rather than handed in. It used to be a parameter so that
    /// the two halves of the Language Servers screen could not disagree
    /// about which extensions exist; there is no second half now, and the
    /// resolver is the same singleton either way.
    @ObservedObject private var languages = LanguageResolver.shared

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

    /// Folded away until asked for. Two dozen languages is the longest
    /// list in this pane and the one least often wanted: the answer for
    /// nearly everybody is the three rows above it.
    @State private var showsLanguages = false

    var body: some View {
        Section {
            Toggle("Suggest as You Type", isOn: $isEnabled)
                .toggleStyle(.switch)

            Picker("Ask for Suggestions", selection: $delayRaw) {
                ForEach(CompletionDelay.allCases) { option in
                    Text(verbatim: Self.title(for: option)).tag(option.rawValue)
                }
            }
            .disabled(!isEnabled)

            Toggle("Include Words from the File", isOn: $usesBufferWords)
                .toggleStyle(.switch)
                .disabled(!isEnabled)

            DisclosureGroup(isExpanded: $showsLanguages) {
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
                    }
                }
            } label: {
                LabeledContent("By Language") {
                    Text(verbatim: languageSummary)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Completion")
        } footer: {
            Text("""
            With Suggest as You Type off, nothing opens the list — not a \
            trigger character, not an explicit request. Nothing below can \
            bring it back; that switch is the master.

            A pause coalesces a burst of typing into one request instead of \
            one per character. A trigger character — a dot, usually — and an \
            explicit request both skip it, because each is already a pause. \
            Words from the file are what still completes when no server is \
            installed for a language, and they rank below anything a server \
            said.

            A language nobody has touched is not stored at all: it follows \
            this build's default, so the default can change without \
            overwriting a choice you made. Only the languages Phantom can \
            complete for are listed.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The picker's own label, adjective and milliseconds together.
    ///
    /// The number used to sit in a read-only row underneath, which restated
    /// the choice above it and — being the one control in the group nothing
    /// disabled — stayed lit after the master switch went off. A
    /// parenthesis carries the same fact without a row, and "Immediately"
    /// needs no number to say what it means.
    private static func title(for option: CompletionDelay) -> String {
        option == .immediate ? option.title : "\(option.title) (\(option.detail))"
    }

    /// What the folded row admits without being opened. The count of
    /// switched-off languages is the only part worth a glance; which they
    /// are is what opening it is for.
    private var languageSummary: String {
        let disabled = CompletionSettingsStore.byLanguage.values.filter { !$0 }.count
        guard disabled > 0 else { return "All Languages" }
        return disabled == 1 ? "1 Language Off" : "\(disabled) Languages Off"
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

        for contributed in languages.catalog.contributed
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
            "toml": "TOML",
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
