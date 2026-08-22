import Foundation

/// The schemas the JSON server is told about, and — the question anyone
/// reading this feature will actually have — the answer to when a schema
/// is downloaded, and by whom.
///
/// Without associations `vscode-json-language-server` is a brace matcher
/// with diagnostics for trailing commas. It reads `$schema` out of a
/// document that declares one, and the two files most worth completing
/// declare nothing: neither `tsconfig.json` nor `package.json` carries a
/// `$schema` key, so on both of them completion and hover answer empty.
///
/// **Phantom never fetches a schema, and never reads SchemaStore's
/// catalogue.** These URLs come from that catalogue — the same source VS
/// Code uses, `https://www.schemastore.org/api/json/catalog.json` — read
/// once by hand and compiled in. Reading it at runtime would mean a
/// download, a cache, a staleness policy and a failure path for each, so
/// that opening a settings pane could put a request on the network; a
/// table this size needs none of it. What that costs is that a schema
/// nobody added here is not offered. A file carrying its own `$schema`
/// still gets one, because that path was never Phantom's.
///
/// **The server fetches, and only for a file that was opened.**
/// `vscode-json-language-server` resolves `https` itself unless the client
/// claims the protocol through `handledSchemaProtocols` — this one does
/// not — and it resolves a schema only when a document matching the
/// pattern is opened. A session that opens no JSON makes no request.
enum JSONSchemaAssociations {
    /// Not a method in the LSP specification: `vscode-json-language-server`
    /// defines it, and handles it by rebuilding its entire schema
    /// configuration from what arrives.
    static let notification = "json/schemaAssociations"

    /// The one server that understands the notification above, which is why
    /// `payload(for:)` is keyed off the command and not off the `json`
    /// language id. That id is one an extension may bring its own server
    /// for, and that server would be sent a notification it has no handler
    /// for — a message some servers log as an error and a few refuse the
    /// connection over.
    static let serverCommand = "vscode-json-language-server"

    /// Glob to schema, each pattern spelled the way SchemaStore's own
    /// catalogue entry spells its `fileMatch`. `tsconfig*.json` rather than
    /// a list of names is what catches the `tsconfig.app.json` and
    /// `tsconfig.node.json` a Vite project splits itself into.
    ///
    /// Patterns are matched by the server against the whole path with `**/`
    /// prefixed, so a bare name matches at any depth.
    ///
    /// **The `.yml` and `.yaml` spellings the catalogue lists beside
    /// `.prettierrc` and `.eslintrc` are deliberately absent.** Those files
    /// go to the YAML server, which keeps its own schema settings; a
    /// pattern for them here would describe documents this server is never
    /// handed.
    static let schemasByFilePattern: [String: String] = [
        "tsconfig*.json": "https://www.schemastore.org/tsconfig.json",
        "jsconfig.json": "https://www.schemastore.org/jsconfig.json",
        "package.json": "https://www.schemastore.org/package.json",
        ".prettierrc": "https://www.schemastore.org/prettierrc.json",
        ".prettierrc.json": "https://www.schemastore.org/prettierrc.json",
        ".eslintrc": "https://www.schemastore.org/eslintrc.json",
        ".eslintrc.json": "https://www.schemastore.org/eslintrc.json",
        ".babelrc": "https://www.schemastore.org/babelrc.json",
        ".babelrc.json": "https://www.schemastore.org/babelrc.json",
        "babel.config.json": "https://www.schemastore.org/babelrc.json",
        ".jscsrc": "https://www.schemastore.org/jscsrc.json",
        ".jshintrc": "https://www.schemastore.org/jshintrc.json",
        ".swcrc": "https://swc.rs/schema.json",
    ]

    /// What to send a freshly initialized server, or nil for a server that
    /// would not know what it was.
    static func payload(for definition: LSPServerDefinition) -> LSPValue? {
        guard definition.command == serverCommand else { return nil }
        return payload
    }

    /// The notification's parameters: one array of schema URLs per pattern,
    /// which is the shape the server folds back into `{uri, fileMatch}` on
    /// the other side.
    static var payload: LSPValue {
        .object(schemasByFilePattern.mapValues { .array([.string($0)]) })
    }
}
