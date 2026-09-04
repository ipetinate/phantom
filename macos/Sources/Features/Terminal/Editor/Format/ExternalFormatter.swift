import Foundation

/// A formatter that is a command, for a language nothing else in this editor
/// formats.
///
/// The gap this fills was measured rather than assumed: every language server
/// in `LSPServerRegistry` was started and asked what it offers, and the answer
/// for Python was that `pyright` has no formatter at all — by design, it says
/// so in its own documentation. Shell is the same story one step removed:
/// `bash-language-server` advertises formatting and shells out to `shfmt`, so
/// a machine without `shfmt` has a server that says yes and does nothing. Lua
/// and XML have no server here at all.
///
/// Prettier is deliberately **not** in this table. It is not one command for
/// one language — it resolves a project, a config and an ignore file, and
/// `PrettierProject` exists to reason about all three. This is for the tools
/// that are genuinely one process: text in, text out.
struct ExternalFormatter: Identifiable, Hashable, Sendable {
    /// The language, spelled as `LSPServerRegistry` spells it where there is
    /// a server for it. It is also the settings key, so it does not change.
    let id: String

    /// The language, as a person says it.
    let languageName: String

    /// The tool, as its own project spells it.
    let displayName: String

    let command: String

    /// Arguments as the tool wants them, with `$FILE` where it wants the name
    /// of the file being formatted.
    ///
    /// The name matters even though the text arrives on stdin: it is how these
    /// tools find their own configuration — `ruff` reads the `pyproject.toml`
    /// above the file, `stylua` reads `stylua.toml` — and how `shfmt` tells
    /// bash from zsh. It is the same reason Prettier is handed
    /// `--stdin-filepath`.
    let arguments: [String]

    /// What the tool is asked to format, lowercased and without the dot.
    let extensions: Set<String>

    let installHint: String

    /// Anything a reader should know before switching it on. Nil for the ones
    /// that simply format.
    let note: String?

    /// The arguments for one file: `$FILE` replaced, everything else as
    /// written.
    func arguments(for path: String) -> [String] {
        arguments.map { $0 == Self.filePlaceholder ? path : $0 }
    }

    static let filePlaceholder = "$FILE"

    /// The command line as a person would type it, for the settings row.
    var invocation: String {
        ([command] + arguments).joined(separator: " ")
    }
}

/// The formatters this editor knows how to run, and the file names each one
/// owns.
///
/// Small on purpose. Every entry is a tool that reads a buffer on stdin and
/// writes the formatted buffer on stdout, that is the standard formatter for
/// its language, and that was checked against a real file before it was
/// written down here.
enum ExternalFormatterRegistry {
    static let all: [ExternalFormatter] = [
        ExternalFormatter(
            id: "python",
            languageName: "Python",
            displayName: "Ruff",
            command: "ruff",
            arguments: ["format", "--stdin-filename", ExternalFormatter.filePlaceholder, "-"],
            extensions: ["py", "pyi"],
            installHint: "brew install ruff",
            /// Named because the alternative is the one people ask about, and
            /// because the answer is reassuring: Ruff's formatter is a
            /// deliberate reimplementation of Black's style, so a project
            /// formatted with Black stays formatted.
            note: "Formats in Black's style. A project using Black is left as Black leaves it."
        ),
        ExternalFormatter(
            id: "shellscript",
            languageName: "Shell",
            displayName: "shfmt",
            command: "shfmt",
            arguments: ["--filename", ExternalFormatter.filePlaceholder],
            extensions: ["sh", "bash", "zsh", "ksh"],
            installHint: "brew install shfmt",
            /// The same binary `bash-language-server` runs. With the server
            /// installed the server gets there first and this never runs; with
            /// only the tool, this is what formats the file.
            note: nil
        ),
        ExternalFormatter(
            id: "lua",
            languageName: "Lua",
            displayName: "StyLua",
            command: "stylua",
            arguments: ["--stdin-filepath", ExternalFormatter.filePlaceholder, "-"],
            extensions: ["lua"],
            installHint: "brew install stylua",
            note: nil
        ),
        ExternalFormatter(
            id: "xml",
            languageName: "XML",
            displayName: "xmllint",
            command: "xmllint",
            arguments: ["--format", "-"],
            extensions: ["xml", "xsd", "xsl", "xslt", "svg", "plist", "storyboard", "xib"],
            installHint: "Ships with macOS at /usr/bin/xmllint",
            /// Measured: handed `<a><b>1</b></a>`, it answers with an XML
            /// declaration the input did not have. Harmless in the files
            /// people keep — a `pom.xml`, an `AndroidManifest.xml` and a
            /// `.plist` all carry one already — and a surprise in a fragment,
            /// which is why it is said out loud in Settings rather than
            /// discovered in a diff.
            note: "Adds an <?xml?> declaration to a file that has none."
        ),
    ]

    static let byID: [String: ExternalFormatter] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// The formatter for a file, before the reader's own settings are applied.
    ///
    /// By extension rather than by language id, deliberately. The id table in
    /// `LSPServerRegistry` only holds languages that have a server, so it
    /// knows nothing about Lua or XML — the two languages here that exist
    /// precisely because nothing serves them.
    static func formatter(forFileNamed name: String) -> ExternalFormatter? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return all.first { $0.extensions.contains(ext) }
    }
}
