import AppKit

/// One thing the editor can do about the code under the caret.
///
/// The engine's own shape for a code action, in the engine's own vocabulary:
/// it says "this rewrites part of this file", not "this carries a
/// `WorkspaceEdit`". A producer translates; the engine presents and applies,
/// and never learns that a language server exists — the same boundary
/// `CodeCompletionItem` sits on, and for the same reason.
///
/// ## What it deliberately cannot express
///
/// **An edit to another file.** `edits` is measured in offsets into the
/// buffer this view is showing, and an offset only means something against
/// the text it was measured on. An action that also rewrites a neighbour is
/// marked `touchesOtherFiles` and handed back to the producer whole, because
/// the producer is the only side that can open the other file, apply to it,
/// and put it on that file's undo stack.
///
/// **A command.** A server is allowed to answer with a name to invoke rather
/// than with text to insert — `source.organizeImports` usually is one — and
/// invoking it is a round trip the engine has no vocabulary for. Same
/// treatment: `runsCommand` is set and the producer runs it.
struct CodeActionItem: Identifiable, Equatable, Sendable {
    /// What sort of action this is, which decides only where it sits in the
    /// menu. A kind the producer could not classify is `.other` rather than
    /// being dropped: an action nobody can name is still an action somebody
    /// can run.
    enum Kind: Int, Equatable, Sendable, CaseIterable {
        case quickFix
        case refactor
        case source
        case other
    }

    /// The producer's handle for this row, opaque here.
    ///
    /// The same device `CodeCompletionItem.resolveToken` uses, and for the
    /// same reason: a resolve has to name the row it is resolving, and the
    /// engine may not hold the producer's own object to name it with.
    let id: Int

    var title: String
    var kind: Kind = .other

    /// The server calling this the obvious answer. It sorts first inside its
    /// group and nothing else.
    var isPreferred = false

    /// Why this cannot be run, or nil when it can. A disabled action is shown
    /// rather than hidden — "Add import (the module has no default export)"
    /// tells the reader something; a row that silently is not there does not.
    var disabledReason: String?

    /// The rewrites to *this* buffer, in its own offsets.
    var edits: [CodeActionEdit] = []

    /// Whether running this also changes a file that is not this one.
    var touchesOtherFiles = false

    /// Whether running this means asking the producer to invoke something.
    var runsCommand = false

    /// Whether the producer might still have edits it has not sent.
    ///
    /// A server is allowed to answer a `codeAction` request with titles alone
    /// and fill in the edits only for the row that was chosen — computing
    /// every fix for every diagnostic on a line is expensive, and most of
    /// them are never taken. A row that says yes here is asked again before
    /// it is applied, which is the same shape, and the same bargain, as
    /// `CodeCompletionItem.mayHaveUnsentEdits`.
    var mayHaveUnsentEdits = false

    var isEnabled: Bool { disabledReason == nil }

    /// Whether the engine can carry this out on its own.
    ///
    /// It cannot if there is nothing to do here, if the work reaches another
    /// file, or if it is a command. Each of those goes back to the producer.
    var isLocal: Bool { !edits.isEmpty && !touchesOtherFiles && !runsCommand }

    /// This row, finished by whatever a resolve came back with.
    ///
    /// Only the parts a resolve is allowed to supply — a server may fill in
    /// the edits it withheld, and may not rename the row under the reader who
    /// just chose it by its name.
    func finished(by resolved: CodeActionItem?) -> CodeActionItem {
        guard let resolved, resolved.id == id else { return self }
        var merged = self
        if !resolved.edits.isEmpty { merged.edits = resolved.edits }
        merged.touchesOtherFiles = touchesOtherFiles || resolved.touchesOtherFiles
        merged.runsCommand = runsCommand || resolved.runsCommand
        merged.mayHaveUnsentEdits = false
        return merged
    }
}

/// One rewrite inside the file being shown.
struct CodeActionEdit: Equatable, Sendable {
    var range: NSRange
    var newText: String
}

/// What the ⌃. menu contains, in order.
///
/// A value rather than menu-building code, so the ordering rule can be
/// asserted without a window or an event — the same reason
/// `EditorContextCommand` is a value.
enum CodeActionMenu {
    enum Row: Equatable {
        case action(CodeActionItem)
        case separator

        /// The menu with nothing in it. Shown rather than not opening at all:
        /// a key that does nothing is indistinguishable from a key that is
        /// not bound, which is precisely the report this whole path came
        /// from.
        case message(String)
    }

    static let emptyMessage = "No fixes available here"

    /// The rows for a set of actions.
    ///
    /// Quick fixes first, because a reader who pressed this pressed it at
    /// something underlined. Refactors next, source actions after them, and
    /// anything unclassified last. Inside a group the server's preferred row
    /// leads and the rest keep the order they arrived in — a server orders
    /// its own answers, and reordering them by title would throw that away.
    ///
    /// A disabled row sinks to the bottom of its own group rather than to the
    /// bottom of the menu: it is still an answer about the same kind of
    /// problem, and moving it past the refactors would file it under the
    /// wrong heading.
    static func rows(for actions: [CodeActionItem]) -> [Row] {
        guard !actions.isEmpty else { return [.message(emptyMessage)] }

        var rows: [Row] = []
        for kind in CodeActionItem.Kind.allCases {
            let group = ordered(actions.filter { $0.kind == kind })
            guard !group.isEmpty else { continue }
            if !rows.isEmpty { rows.append(.separator) }
            rows.append(contentsOf: group.map { Row.action($0) })
        }
        return rows.isEmpty ? [.message(emptyMessage)] : rows
    }

    /// Stable within a group: enabled before disabled, preferred before the
    /// rest, and arrival order deciding everything else. Spelled with the
    /// index carried along because `sorted(by:)` is not a stable sort in
    /// Swift, and a menu whose rows swap places between two presses is worse
    /// than one in an order nobody chose.
    private static func ordered(_ actions: [CodeActionItem]) -> [CodeActionItem] {
        actions.enumerated()
            .sorted { left, right in
                let first = left.element
                let second = right.element
                if first.isEnabled != second.isEnabled { return first.isEnabled }
                if first.isPreferred != second.isPreferred { return first.isPreferred }
                return left.offset < right.offset
            }
            .map(\.element)
    }
}
