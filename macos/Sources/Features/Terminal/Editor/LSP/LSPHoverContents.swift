import Foundation

/// A `textDocument/hover` payload, flattened to the markdown the card draws.
///
/// The protocol allows three shapes under `contents` and only one of them is
/// already markdown. `MarkupContent` — `{kind, value}` — is; a plain string
/// is; and `MarkedString` in its object form — `{language, value}` — is
/// **code in a named language with the fences left off**, which is a
/// different thing entirely.
///
/// Reading the `value` out of all three and calling the result markdown is
/// what this type exists to stop, because the third shape then arrives at
/// `CodeHoverInfo.split` with no fence to recognise. Everything in it is
/// therefore prose, and prose is *reflowed*: a single newline becomes a
/// space. Measured against `tailwindcss-language-server` 0.16.0, which
/// answers every class with
///
/// ```
/// {"language": "css", "value": ".flex {\n  display: flex;\n}"}
/// ```
///
/// — three lines of CSS that reached the card as one run-on line of body
/// text. Restoring the fence puts it back where the splitter can find it,
/// and the card already draws a leading fenced block in the editor's own
/// font through its highlighter.
///
/// Pure and separate from `LSPCenter` so the shapes can be pinned down as
/// values; `LSPCenter.hoverText(from:)` is the one caller.
enum LSPHoverContents {
    /// Markdown for a `contents` value, or nil when there is nothing to say.
    ///
    /// Empty is nil rather than an empty string at every level, including
    /// inside an array: the card checks `isEmpty` before opening a window, so
    /// a blank string here is a blank card floating over the code.
    static func markdown(from contents: LSPValue?) -> String? {
        guard let contents else { return nil }

        if let text = contents.stringValue { return text.isEmpty ? nil : text }

        if let value = contents["value"]?.stringValue {
            guard !value.isEmpty else { return nil }

            /// `language` is what separates a `MarkedString` from a
            /// `MarkupContent`; the latter carries `kind` and is markdown
            /// already, so it passes through untouched.
            guard let language = contents["language"]?.stringValue, !language.isEmpty else {
                return value
            }
            return "```\(language)\n\(value)\n```"
        }

        if let array = contents.arrayValue {
            let joined = array.compactMap { markdown(from: $0) }.joined(separator: "\n\n")
            return joined.isEmpty ? nil : joined
        }

        return nil
    }
}
