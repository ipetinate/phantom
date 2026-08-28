import Foundation

/// The side channel `@vue/language-server` 3.x needs, and the reason a
/// `.vue` template can offer a component the file has not imported yet.
///
/// Version 3 dropped the in-process TypeScript project that version 2 could
/// fall back to. Everything type-aware now lives in `tsserver`, behind a
/// handful of commands the Vue tooling adds to it — `_vue:projectInfo`,
/// `_vue:getComponentNames`, `_vue:getAutoImportSuggestions`,
/// `_vue:resolveAutoImportCompletionEntry` and a dozen more. LSP has no
/// request for any of them, so the server asks the *client* to relay them:
/// it sends a `tsserver/request` notification and waits for a
/// `tsserver/response` notification carrying the answer.
///
/// **The relay is not optional.** The server resolves which language service
/// serves a file by asking `_vue:projectInfo` first, and awaits that answer
/// before it will handle anything. A client that ignores the notification
/// gets a server that completes `initialize` and then never answers again —
/// measured, not inferred. So every request is answered here, including with
/// a null body, and never dropped.
///
/// The other end is `typescript-language-server`, which already serves the
/// `<script>` half of every `.vue` and already loads
/// `@vue/typescript-plugin`. It exposes `typescript.tsserverRequest` as a
/// workspace command that forwards an arbitrary command to the `tsserver` it
/// drives — so no second `tsserver` is spawned, and the process answering
/// the template's questions is the same one that holds the project.
///
/// This type is only the translation between the two shapes. Which servers
/// are involved, and what to do when one of them is not running, is
/// `LSPCenter`'s.
enum LSPTSServerBridge {
    /// What the Vue server sends when it needs `tsserver`.
    static let requestMethod = "tsserver/request"

    /// What it waits for in return.
    static let responseMethod = "tsserver/response"

    /// `typescript-language-server`'s passthrough to the `tsserver` it owns.
    static let executeCommandName = "typescript.tsserverRequest"

    /// One question, on its way to `tsserver`.
    struct Request: Hashable, Sendable {
        /// The Vue server's own correlation id. Echoed back untouched — it
        /// is the server's number, and this side has no business reading it
        /// as anything but a token.
        let id: LSPValue

        /// A `tsserver` command name, `_vue:`-prefixed for the ones the
        /// plugin adds.
        let command: String

        /// Whatever that command takes: an object for the commands
        /// `tsserver` defines itself, a positional array for the plugin's.
        /// Passed through unread.
        let arguments: LSPValue
    }

    /// The request inside a `tsserver/request` notification, or nil if this
    /// is not one.
    ///
    /// The params are a **nested** array — `[[id, command, arguments]]` —
    /// because `vscode-jsonrpc` sends a notification's single argument as a
    /// one-element parameter list. Reading the outer array as the triple is
    /// the mistake that makes the command come out `nil`, and a bridge that
    /// then answers nothing is the hang described above. The unnested shape
    /// is accepted too, so the reading does not depend on which side of that
    /// convention a future version lands on.
    static func request(in notification: LSPNotification) -> Request? {
        guard notification.method == requestMethod else { return nil }
        guard let params = notification.params?.arrayValue else { return nil }

        let triple = params.count == 1 ? (params[0].arrayValue ?? params) : params
        guard triple.count >= 2, let command = triple[1].stringValue else { return nil }

        return Request(
            id: triple[0],
            command: command,
            arguments: triple.count > 2 ? triple[2] : .null
        )
    }

    /// The file a request is about, when it names one.
    ///
    /// Two shapes, because the commands `tsserver` defines take an object
    /// with a `file` and the ones the plugin adds take the file name as
    /// their first positional argument. Both are read, because the caller
    /// wants the same thing from either: whether the process about to be
    /// asked has been told this document exists.
    static func fileName(in request: Request) -> String? {
        if let file = request.arguments["file"]?.stringValue { return file }
        return request.arguments.arrayValue?.first?.stringValue
    }

    /// The `workspace/executeCommand` params that carry one request to
    /// `typescript-language-server`.
    ///
    /// The third argument is the wrapper's own execution options. It is sent
    /// explicitly rather than left out because the wrapper spreads it over
    /// its defaults, and the two that matter are the ones that make this a
    /// question rather than a fire-and-forget: an answer is expected, and it
    /// is expected synchronously.
    static func executeCommandParams(for request: Request) -> LSPValue {
        [
            "command": .string(executeCommandName),
            "arguments": .array([
                .string(request.command),
                request.arguments,
                ["expectsResult": true, "isAsync": false],
            ]),
        ]
    }

    /// The answer, in the shape the Vue server reads it back out of.
    ///
    /// Nested for the same reason `request(in:)` un-nests: the server's
    /// handler destructures its first parameter as `[id, response]`.
    static func responseParams(id: LSPValue, body: LSPValue) -> LSPValue {
        .array([.array([id, body])])
    }

    /// The part of a `tsserver` reply the Vue server wants.
    ///
    /// `typescript-language-server` hands back the whole `tsserver` response
    /// envelope — `seq`, `command`, `success`, `body`. The Vue server expects
    /// only the body, and a failed command is reported by handing it nothing
    /// rather than by handing it the envelope: the callers there read the
    /// answer's fields directly, and an envelope would satisfy every optional
    /// check while being the wrong object.
    static func body(of result: LSPValue) -> LSPValue {
        guard result["success"]?.boolValue != false else { return .null }
        return result["body"] ?? .null
    }
}
