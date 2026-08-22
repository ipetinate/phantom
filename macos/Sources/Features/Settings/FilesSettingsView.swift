import SwiftUI

/// The editor's own preferences.
///
/// Separate from Appearance because these are about *reading and editing a
/// file*, not about how the app looks — the editor's font is the one you
/// want big enough to work in, which is rarely the same answer as the
/// terminal's.
struct FilesSettingsView: View {
    @AppStorage(FileOpenAction.defaultsKey)
    private var clickAction = FileOpenAction.builtInEditor.rawValue

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
            } header: {
                Text("Opening")
            } footer: {
                Text("Whatever you pick here, the other ways stay available from a file's context menu — so \"Open With…\" can still send this one file to vim or to another app.")
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
                        Text("\(Int(fontSize))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Tab Width", selection: $tabWidth) {
                    Text("2").tag(2)
                    Text("4").tag(4)
                    Text("8").tag(8)
                }
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
                Text("Files larger than \(sizeLimit) or containing binary data open in an external app instead — there is nothing readable to show, and loading them would stall the window. Images and PDFs are shown in the editor instead of being refused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Its own section rather than three more rows under Display,
            // because these change what ends up *in the file* while
            // everything above only changes how it is drawn. Somebody
            // turning off the minimap is rearranging their window; somebody
            // turning off tag closing is changing what their keyboard does.
            Section {
                Toggle("Close Brackets", isOn: $closesBrackets)
                    .toggleStyle(.switch)
                Toggle("Close Quotes", isOn: $closesQuotes)
                    .toggleStyle(.switch)
                Toggle("Close Tags", isOn: $closesTags)
                    .toggleStyle(.switch)
                Toggle("Markdown Snippets on /", isOn: $markdownSnippets)
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
                language server keeps the rest. Its own config is honoured whatever \
                the format — including `prettier.config.mjs`, which only Prettier \
                itself can read.

                Honouring the project's version and plugins means running the \
                `prettier` inside its `node_modules`, which is code from the folder \
                you opened rather than from this app. Turn this off to keep \
                formatting on the language server.

                Formatting never blocks a save: if Prettier is missing, slow or \
                unhappy, the file is still written.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Files")
        .sheet(isPresented: $isChoosingFont) {
            // The terminal preview, because that is what the editor is:
            // monospaced code on the theme's background. Reusing the same
            // picker the terminal and interface fonts already use keeps
            // one search-and-preview instead of three.
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
