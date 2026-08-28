import Foundation

/// One thing a server offers to do to the file at a position — a quick fix,
/// a refactor, a source action.
///
/// Deliberately close to the wire, for the same reason `LSPCompletion` is: a
/// field dropped here has to be guessed later, and two of the fields below
/// are the difference between an action that works and one that silently
/// does nothing.
///
/// The protocol allows two shapes in the same array and a client that reads
/// only one gets nothing from half the servers. A `CodeAction` is the rich
/// form — a title, a kind, an edit, and possibly a command. A bare `Command`
/// is the old form, and `jdtls` and `kotlin-language-server` still send it:
/// a title and a command name, with the work happening on the server when it
/// is executed. Both parse into this.
struct LSPCodeAction: Identifiable, Equatable {
    /// A command to run on the server, with its arguments.
    ///
    /// Kept as the server sent them. The arguments are opaque — they name
    /// the server's own internal handles, and re-encoding them through a
    /// type of ours would hand back a value the server cannot match.
    struct Invocation: Equatable {
        let command: String
        let arguments: [LSPValue]
    }

    /// Position in the merged menu. Identity for a list that is rebuilt on
    /// every request, which is all identity has to be here.
    ///
    /// Assigned twice: once by the parse, per server, and again by
    /// `merged(_:)` once the menu is one list. Only the second numbering is
    /// the one a caller sees, and it is why this is not a `let` — a menu
    /// where two servers both start at zero has two rows claiming the same
    /// identity, and a list that draws by id shows one of them twice.
    var id: Int

    var title: String

    /// `quickfix`, `refactor.extract`, `source.organizeImports` — the
    /// protocol's hierarchical strings, unparsed.
    ///
    /// Unparsed on purpose. The set is open: a server may send a kind no
    /// enum here would have, and `refactor.extract.function` has to sort
    /// with `refactor.extract` rather than fall to an `other` case. A caller
    /// that wants a group matches on the prefix.
    var kind: String?

    /// The server saying "this is the one they probably meant". Draws first
    /// and is what a default action would run.
    var isPreferred: Bool

    /// Set when the server offered the action **and** said it cannot be
    /// applied here, with a sentence saying why.
    ///
    /// Shown greyed rather than hidden, which is the protocol's own advice
    /// and the useful behaviour: "Extract to function — selection spans a
    /// return statement" tells the reader what to change, and an action
    /// silently missing from the menu tells them nothing.
    var disabledReason: String?

    /// What to change, keyed by path. The shape `rename` already returns.
    var edit: [String: [LSPTextEdit]]

    /// Run instead of, or after, the edit.
    ///
    /// Both are possible in one action and the order is fixed by the
    /// specification: apply the edit first, then execute the command.
    var command: Invocation?

    /// The action carries no work yet and the server can fill it in.
    ///
    /// The protocol lets a server send a title and nothing else, then
    /// compute the edit only for the action the reader actually chose —
    /// which for "organize imports" across a large program is the
    /// difference between a menu that opens instantly and one that does not.
    /// An action in this state must be resolved before it is applied, and
    /// applying it unresolved is a menu entry that does nothing.
    var needsResolve: Bool

    /// The server's own payload, kept **verbatim** for `codeAction/resolve`.
    ///
    /// Same rule as `LSPCompletion.raw`: it is the action's identity as far
    /// as the server is concerned, and resolve has to be handed back the
    /// value it was given.
    let raw: LSPValue

    /// Which of the file's servers offered this action, by command.
    ///
    /// A `.vue` has two and both may offer actions. Resolving or executing
    /// against the wrong one fails — see `LSPCompletion.origin`, which
    /// exists for the same reason and was measured.
    var origin: String?

    /// Whether this action can be applied as it stands.
    var isApplicable: Bool { disabledReason == nil }

    /// Whether anything would happen if it were applied now.
    var hasWork: Bool { !edit.isEmpty || command != nil }

    static func == (lhs: LSPCodeAction, rhs: LSPCodeAction) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.kind == rhs.kind
            && lhs.isPreferred == rhs.isPreferred
            && lhs.disabledReason == rhs.disabledReason
            && lhs.edit == rhs.edit
            && lhs.command == rhs.command
            && lhs.needsResolve == rhs.needsResolve
            && lhs.raw == rhs.raw
            && lhs.origin == rhs.origin
    }

    /// - Parameter canResolve: Whether the server that sent this advertised
    ///   `codeActionProvider.resolveProvider`. Passed in rather than read
    ///   here because it is a fact about the server, not about the action —
    ///   and marking an action resolvable on a server that answers no
    ///   resolve produces a menu entry that can never do anything.
    init?(_ value: LSPValue, index: Int = 0, canResolve: Bool = false, origin: String? = nil) {
        guard let title = value["title"]?.stringValue else { return nil }

        self.id = index
        self.title = title
        self.raw = value
        self.origin = origin
        self.isPreferred = value["isPreferred"]?.boolValue ?? false
        self.disabledReason = value["disabled"]?["reason"]?.stringValue

        /// The bare `Command` form: `command` is the name itself rather than
        /// an object. Read the rich form's `command.command` from it and a
        /// server's whole menu comes back titled and inert.
        if let name = value["command"]?.stringValue {
            self.kind = value["kind"]?.stringValue
            self.edit = [:]
            self.command = Invocation(
                command: name,
                arguments: value["arguments"]?.arrayValue ?? []
            )
            self.needsResolve = false
            return
        }

        self.kind = value["kind"]?.stringValue
        self.edit = value["edit"].map(LSPCenter.workspaceEdits(from:)) ?? [:]

        if let invocation = value["command"], let name = invocation["command"]?.stringValue {
            self.command = Invocation(
                command: name,
                arguments: invocation["arguments"]?.arrayValue ?? []
            )
        } else {
            self.command = nil
        }

        self.needsResolve = canResolve && self.edit.isEmpty && self.command == nil
    }

    /// The action after `codeAction/resolve` answered.
    ///
    /// Only the edit and the command are taken. Everything else stays as the
    /// list had it, so a resolve cannot change the title under a menu that is
    /// already drawn, nor take the identity or the ordering with it — the
    /// same rule as `LSPCompletion.merging(resolved:)`.
    func merging(resolved: LSPValue) -> LSPCodeAction {
        var merged = self

        let edits = LSPCenter.workspaceEdits(from: resolved["edit"] ?? .null)
        if !edits.isEmpty { merged.edit = edits }

        if let invocation = resolved["command"], let name = invocation["command"]?.stringValue {
            merged.command = Invocation(
                command: name,
                arguments: invocation["arguments"]?.arrayValue ?? []
            )
        }

        merged.needsResolve = !merged.hasWork
        return merged
    }
}

extension LSPCodeAction {
    /// One menu out of what a file's several servers answered.
    ///
    /// **Whole actions, concatenated in the order given, first occurrence
    /// wins** — the same rule as diagnostics and completions, and for the
    /// same reason: each server maps a single-file component's positions
    /// through its own copy of the language tooling, so an edit from one
    /// combined with a range from another lands in the wrong place.
    ///
    /// Deduped on the title *and* the kind. Title alone would drop a
    /// genuinely different action that happens to share a name — "Add all
    /// missing imports" as a `quickfix` and as a `source` action are two
    /// entries with two behaviours.
    ///
    /// The ids are assigned here, after the merge, so they number the menu
    /// the reader sees rather than one server's slice of it.
    static func merged(_ lists: [[LSPCodeAction]]) -> [LSPCodeAction] {
        var seen: Set<String> = []
        var merged: [LSPCodeAction] = []

        for list in lists {
            for action in list where seen.insert(action.title + "\u{0}" + (action.kind ?? "")).inserted {
                var renumbered = action
                renumbered.id = merged.count
                merged.append(renumbered)
            }
        }

        return merged
    }

    /// A server's answer to `textDocument/codeAction`, parsed.
    ///
    /// Null and a bare array are both legal answers, and an entry that is
    /// neither shape is dropped rather than allowed to shift every id after
    /// it.
    static func list(
        from value: LSPValue,
        canResolve: Bool = false,
        origin: String? = nil
    ) -> [LSPCodeAction] {
        (value.arrayValue ?? []).enumerated().compactMap {
            LSPCodeAction($0.element, index: $0.offset, canResolve: canResolve, origin: origin)
        }
    }

    /// The `context` half of a `textDocument/codeAction` request.
    ///
    /// - Parameter diagnostics: **The server's own**, verbatim. This is the
    ///   field quick fixes live or die on: `typescript-language-server`
    ///   matches a fix to a diagnostic by its `code`, and a diagnostic
    ///   re-encoded from a parsed type has no `code` — so the request
    ///   succeeds, the refactors come back, and every quick fix is missing
    ///   with nothing reported anywhere.
    static func context(diagnostics: [LSPValue]) -> LSPValue {
        ["diagnostics": .array(diagnostics)]
    }
}

/// What a server said about code actions at `initialize`.
///
/// Three answers, not two, and collapsing them to two costs a whole server's
/// menu either way.
///
/// `codeActionProvider` is a plain `true` on several servers — reading only
/// the object form skips them. It is **absent** on a server that registers
/// the feature later through `client/registerCapability`, which this client
/// acknowledges without recording; treating absence as a refusal would skip
/// those permanently. Only an explicit `false` is a refusal.
struct LSPCodeActionCapability: Equatable {
    /// The server said it serves code actions.
    let isDeclared: Bool

    /// The server said it does **not**. The only case worth skipping.
    let isRefused: Bool

    /// The edit may arrive on `codeAction/resolve` rather than in the menu.
    let resolveProvider: Bool

    /// Whether to send this server a request at all.
    var isWorthAsking: Bool { !isRefused }

    init(_ capabilities: LSPValue?) {
        let provider = capabilities?["codeActionProvider"]

        switch provider {
        case .bool(let flag):
            self.isDeclared = flag
            self.isRefused = !flag
            self.resolveProvider = false
        case .object:
            self.isDeclared = true
            self.isRefused = false
            self.resolveProvider = provider?["resolveProvider"]?.boolValue ?? false
        default:
            self.isDeclared = false
            self.isRefused = false
            self.resolveProvider = false
        }
    }
}

extension LSPCodeAction {
    /// The commands a server said it can execute.
    ///
    /// Empty means the server named none — either it advertised no
    /// `executeCommandProvider` at all, or it advertised an empty list. Both
    /// are read as "no claim", not as "refuses everything": a server with no
    /// list is asked anyway, because refusing to ask would take away every
    /// command action from a server that simply did not enumerate them.
    static func executeCommands(in capabilities: LSPValue?) -> Set<String> {
        let commands = capabilities?["executeCommandProvider"]?["commands"]?.arrayValue ?? []
        return Set(commands.compactMap(\.stringValue))
    }

    /// Whether one of `edit`'s keys names the file at `ownPath`.
    ///
    /// The keys are **paths**, not URIs: `LSPCenter.workspaceEdits(from:)`
    /// has already turned the server's `file://` spelling into one. So the
    /// comparison is between two paths, resolved before comparing — a symlink
    /// or an unstandardised component would otherwise make an action on this
    /// very file look like an action on another one, which would send it back
    /// to be applied a file at a time instead of in one undo step here.
    static func isSameFile(_ path: String, as ownPath: String) -> Bool {
        guard path != ownPath else { return true }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: ownPath).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
