import SwiftUI

/// The editor's own preferences.
///
/// Separate from Appearance because these are about *reading and editing a
/// file*, not about how the app looks — the editor's font is the one you
/// want big enough to work in, which is rarely the same answer as the
/// terminal's.
///
/// It also carries what happens when a file is clicked, which is about the
/// file rather than the text but belongs to whoever opens it. How the
/// explorer itself is set up lives with the sidebar, in
/// `FileExplorerSettingsSection` — the explorer is a sidebar pane, and
/// asking about it here meant asking in the room named after what it
/// opens.
struct FilesSettingsView: View {
    @AppStorage(FileOpenAction.defaultsKey)
    private var clickAction = FileOpenAction.builtInEditor.rawValue

    @AppStorage(FileOpenTarget.defaultsKey)
    private var fileOpenTarget = FileOpenTarget.alwaysNewTerminal.rawValue

    /// Empty means "use `FileOpener.defaultEditor`", which is what the
    /// field's prompt shows — so clearing it is how you get back to the
    /// default, and there is no separate reset to explain.
    @AppStorage(FileOpener.editorKey) private var terminalEditor = ""

    @AppStorage(EditorSettings.fontSizeKey) private var fontSize = EditorSettings.defaultFontSize
    @AppStorage(EditorSettings.fontFamilyKey) private var fontFamily = ""
    @AppStorage(EditorSettings.wrapsLinesKey) private var wrapsLines = false
    @AppStorage(EditorSettings.showsLineNumbersKey) private var showsLineNumbers = true
    @AppStorage(EditorSettings.tabWidthKey) private var tabWidth = EditorSettings.defaultTabWidth
    @AppStorage(EditorSettings.showsMinimapKey) private var showsMinimap = true
    @AppStorage(EditorSettings.colorsBracketPairsKey) private var colorsBracketPairs = true
    @AppStorage(EditorSettings.closesBracketsKey) private var closesBrackets = true
    @AppStorage(EditorSettings.closesQuotesKey) private var closesQuotes = true
    @AppStorage(EditorSettings.closesTagsKey) private var closesTags = true
    @AppStorage(EditorSettings.formatOnSaveKey) private var formatOnSave = false
    @AppStorage(EditorSettings.usesPrettierKey) private var usesPrettier = true
    @AppStorage(EditorSettings.markdownSnippetsKey) private var markdownSnippets = true

    @State private var isChoosingFont = false

    var body: some View {
        Form {
            Section {
                Picker("Clicking a File", selection: $clickAction) {
                    ForEach(FileOpenAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }

                /// Directly under the choice it depends on. This lived two
                /// panes away, under a header that read "Panels", and only
                /// means anything when the row above sends the file to a
                /// terminal — which `FileOpener.reusableTerminal` is the
                /// only consumer of.
                Picker("In a Terminal", selection: $fileOpenTarget) {
                    ForEach(FileOpenTarget.allCases) { target in
                        Text(target.title).tag(target.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(clickAction != FileOpenAction.terminalEditor.rawValue)

                /// Not disabled alongside the row above, deliberately. The
                /// command runs whenever a file reaches a terminal, and the
                /// picker is only one of the ways it gets there — the
                /// three-way dialog and the context menu send files to a
                /// terminal whatever "Clicking a File" says, so greying
                /// this out would hide the setting from the people using
                /// it most deliberately.
                LabeledContent("Terminal Editor Command") {
                    TextField(
                        "",
                        text: $terminalEditor,
                        prompt: Text(verbatim: FileOpener.defaultEditor)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                }
            } header: {
                Text("Opening")
            } footer: {
                Text("""
                Whatever you pick here, the other ways stay available from a \
                file's context menu — so "Open With…" can still send this one \
                file to vim or to another app. Reuse applies only to a \
                terminal sitting at a prompt: one still running something \
                always gets a new terminal, so a command can never land \
                inside whatever is already open there.

                The terminal command is a shell expression rather than a \
                path, and your login shell is what runs it — which is what \
                lets `${EDITOR:-vim}` pick up a variable this app never \
                inherits. The file's path is appended, quoted.

                Files larger than \(sizeLimit) or holding binary data go to \
                an external app instead: there is nothing readable to show, \
                and loading them would stall the window. Images and PDFs are \
                drawn in the editor rather than refused.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text") {
                LabeledContent("Font") {
                    Button(fontFamily.isEmpty ? "System Monospace" : fontFamily) {
                        isChoosingFont = true
                    }
                }

                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Slider(value: $fontSize, in: 9...24, step: 1)
                            .frame(width: 180)
                        Text(verbatim: "\(Int(fontSize))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                /// Three values, all one character wide. A pop-up spends a
                /// click hiding two of them.
                Picker("Tab Width", selection: $tabWidth) {
                    Text("2").tag(2)
                    Text("4").tag(4)
                    Text("8").tag(8)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Wrap Long Lines", isOn: $wrapsLines)
                    .toggleStyle(.switch)
                Toggle("Show Line Numbers", isOn: $showsLineNumbers)
                    .toggleStyle(.switch)
                Toggle("Show Minimap", isOn: $showsMinimap)
                    .toggleStyle(.switch)
                Toggle("Color Bracket Pairs", isOn: $colorsBracketPairs)
                    .toggleStyle(.switch)
            } header: {
                Text("Display")
            } footer: {
                Text("""
                None of these changes the file, only how it is drawn. \
                Wrapping decides where a line ends on screen and never where \
                it ends on disk, so a wrapped file and an unwrapped one are \
                byte for byte the same.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            /// Its own section rather than three more rows under Display,
            /// because these change what ends up *in the file* while
            /// everything above only changes how it is drawn. Somebody
            /// turning off the minimap is rearranging their window; somebody
            /// turning off tag closing is changing what their keyboard does.
            Section {
                Toggle("Close Brackets", isOn: $closesBrackets)
                    .toggleStyle(.switch)
                Toggle("Close Quotes", isOn: $closesQuotes)
                    .toggleStyle(.switch)
                Toggle("Close Tags", isOn: $closesTags)
                    .toggleStyle(.switch)
                Toggle("Markdown Snippets on “/”", isOn: $markdownSnippets)
                    .toggleStyle(.switch)
            } header: {
                Text("Typing")
            } footer: {
                Text("""
                Tags close in HTML, Vue and JSX. They deliberately do not in \
                .ts, where a `<` is always a generic and closing it would \
                always be wrong.

                In Markdown, typing `/` opens the snippet list — a bare slash \
                lists everything. It stays shut inside fenced code, and after \
                a word character, so `and/or` and `https://` are left alone.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Format on Save", isOn: $formatOnSave)
                    .toggleStyle(.switch)
                Toggle("Use the Project's Prettier", isOn: $usesPrettier)
                    .toggleStyle(.switch)
            } header: {
                Text("Formatting")
            } footer: {
                Text("""
                A project carrying a Prettier config has already decided how its \
                files are written, so Prettier formats the ones it handles and the \
                language server keeps the rest. Its own config is honored whatever \
                the format — including `prettier.config.mjs`, which only Prettier \
                itself can read.

                Honoring the project's version and plugins means running the \
                `prettier` inside its `node_modules`, which is code from the folder \
                you opened rather than from this app. Turn this off to keep \
                formatting on the language server.

                Formatting never blocks a save: if Prettier is missing, slow or \
                unhappy, the file is still written.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            /// Directly under Formatting, because it is the rest of the same
            /// answer: that section says what happens to the files Prettier
            /// and the language servers handle, and this one says what happens
            /// to the languages neither of them formats.
            ExternalFormatterSettingsSection()

            /// Above Completion, and next to Formatting, because that is the
            /// order of the question: what does this editor do on its own,
            /// and then how does the one behaviour with a table of its own
            /// behave.
            EditorFeatureSettingsSection()

            CompletionSettingsSection()

        }
        .formStyle(.grouped)
        .navigationTitle("Editor")
        .sheet(isPresented: $isChoosingFont) {
            /// The terminal preview, because that is what the editor is:
            /// monospaced code on the theme's background. Reusing the same
            /// picker the terminal and interface fonts already use keeps
            /// one search-and-preview instead of three.
            FontPickerView(
                currentFamily: fontFamily.isEmpty ? nil : fontFamily,
                preview: .terminal,
                onPick: { family in
                    fontFamily = family ?? ""
                    isChoosingFont = false
                },
                onCancel: { isChoosingFont = false }
            )
        }
    }

    private var sizeLimit: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(FileOpenGuard.maxBytes),
            countStyle: .file
        )
    }

}
