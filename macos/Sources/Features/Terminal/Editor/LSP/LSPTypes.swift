import Foundation

/// A position in a document, as the protocol counts them.
///
/// **Zero-based lines, and columns in UTF-16 code units** — not characters,
/// not bytes. Getting this wrong is the classic LSP bug: everything works
/// until a line contains an emoji or an accent, and from there every
/// position on that line is off by one per character, so diagnostics
/// underline the wrong word and go-to-definition lands in the wrong place.
/// `NSString` is also UTF-16, which is what makes the conversion below a
/// direct one rather than a re-encoding.
struct LSPPosition: Equatable, Hashable {
    var line: Int
    var character: Int

    var value: LSPValue {
        ["line": .integer(line), "character": .integer(character)]
    }

    init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    init?(_ value: LSPValue?) {
        guard let line = value?["line"]?.intValue,
              let character = value?["character"]?.intValue
        else { return nil }
        self.line = line
        self.character = character
    }
}

struct LSPRange: Equatable, Hashable {
    var start: LSPPosition
    var end: LSPPosition

    var value: LSPValue { ["start": start.value, "end": end.value] }

    init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    init?(_ value: LSPValue?) {
        guard let start = LSPPosition(value?["start"]),
              let end = LSPPosition(value?["end"])
        else { return nil }
        self.start = start
        self.end = end
    }
}

/// Converting between the protocol's coordinates and `NSRange`.
///
/// Kept as free functions over an `NSString` so both directions are pure
/// and testable — this is the piece most worth being sure about, since a
/// mistake here misplaces every feature at once rather than breaking one.
enum LSPTextCoordinates {
    /// Byte-free line starts: each entry is the UTF-16 offset where that
    /// zero-based line begins.
    ///
    /// Walking the whole document, so anything converting more than one
    /// position should build an `LSPLineIndex` once instead of calling the
    /// helpers below in a loop.
    static func lineStarts(in text: NSString) -> [Int] {
        var starts = [0]
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.byLines, .substringNotRequired]
        ) { _, _, enclosing, _ in
            let next = enclosing.location + enclosing.length
            if next < text.length { starts.append(next) }
        }
        return starts
    }

    static func offset(of position: LSPPosition, in text: NSString) -> Int? {
        LSPLineIndex(text).offset(of: position)
    }

    static func position(at offset: Int, in text: NSString) -> LSPPosition {
        LSPLineIndex(text).position(at: offset)
    }

    static func range(of range: LSPRange, in text: NSString) -> NSRange? {
        LSPLineIndex(text).range(of: range)
    }
}

/// The line starts of one document, computed once.
///
/// The helpers above each walk the whole document to answer a single
/// question, which is fine for one conversion and quadratic for a batch —
/// and a batch is the normal case: a file with sixty diagnostics was
/// scanning itself sixty times, on the main thread, every time SwiftUI
/// re-evaluated the view. Build this once and ask it repeatedly.
struct LSPLineIndex {
    private let starts: [Int]
    private let length: Int

    init(_ text: NSString) {
        self.starts = LSPTextCoordinates.lineStarts(in: text)
        self.length = text.length
    }

    func offset(of position: LSPPosition) -> Int? {
        guard position.line >= 0, position.line < starts.count else { return nil }
        return min(starts[position.line] + position.character, length)
    }

    func position(at offset: Int) -> LSPPosition {
        let clamped = max(0, min(offset, length))

        // Binary search rather than a scan: this is asked once per hover and
        // once per click, but on a document with a hundred thousand lines a
        // linear walk is felt.
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= clamped { low = middle } else { high = middle - 1 }
        }
        return LSPPosition(line: low, character: clamped - starts[low])
    }

    func range(of range: LSPRange) -> NSRange? {
        guard let start = offset(of: range.start),
              let end = offset(of: range.end),
              end >= start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

/// Prose from a server, with the kind it was written in.
///
/// The kind is not decoration and must not be flattened away. A renderer has
/// to know whether it may run `CodeHoverInfo.split(markdown:)` over the text:
/// on markdown that is what separates the declaration from its documentation,
/// and on plain text the same pass eats horizontal rules, reflows paragraphs
/// that meant to keep their breaks, and treats a line of backticks as a fence.
///
/// `documentation` arrives as a bare string on some servers and as a
/// `MarkupContent` on others, so both shapes parse here rather than at every
/// call site.
struct LSPMarkupContent: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case plaintext
        case markdown
    }

    let kind: Kind
    let value: String

    init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    /// Nil for absent *and* for empty, so nothing downstream has to tell an
    /// empty string apart from no documentation at all.
    ///
    /// An unrecognised kind is read as plain text, which is the conservative
    /// direction: markdown drawn as plain text shows a few stray asterisks,
    /// while plain text run through a markdown splitter loses content.
    init?(_ value: LSPValue?) {
        guard let value else { return nil }

        let text = value.stringValue ?? value["value"]?.stringValue
        guard let text, !text.isEmpty else { return nil }

        self.value = text
        self.kind = Kind(rawValue: value["kind"]?.stringValue ?? "") ?? .plaintext
    }
}

/// How long each kind of request may take before it is abandoned.
///
/// Per method rather than one global thirty seconds, because the deadlines
/// are answering different questions. `initialize` on a cold Gradle project
/// legitimately takes twenty seconds and nobody is staring at a popup while
/// it happens. A completion that arrives after the user has typed three more
/// characters is worse than no completion at all, since by then it describes
/// a prefix that is gone.
enum LSPTimeout {
    /// The typing path. Deliberately not tighter: measured, both
    /// `typescript-language-server` and `kotlin-language-server` need
    /// 500–900ms for the first completion in a cold project, and a budget
    /// under a second makes the feature look broken exactly where a first
    /// impression is formed.
    static let completionWhileTyping: TimeInterval = 1.5

    /// ⌃Space. Somebody who asked out loud is willing to wait.
    static let completionExplicit: TimeInterval = 5

    /// `completionItem/resolve`. Never on the typing path — it runs on a
    /// selection settling or at accept time, where a person is already
    /// paused.
    static let completionResolve: TimeInterval = 2

    /// `initialize`, formatting, rename: things a person waits for on
    /// purpose, and where giving up early is the failure.
    static let deliberate: TimeInterval = 30
}

/// The debounced `didChange` text waiting to be sent, per document.
///
/// Carved out of `LSPCenter` for one reason: the ordering bug it exists to
/// prevent is invisible from the outside. Full-document sync means a dropped
/// change is repaired by the *next* keystroke, so losing one is only
/// observable if the user stops typing — which is exactly when completion,
/// hover and save ask their questions. Two operations on a value can be
/// tested directly; the same three lines inside a class that spawns
/// processes and watches directories cannot.
@MainActor
struct LSPPendingChanges {
    private var texts: [String: String] = [:]

    /// The documents with something waiting. A copy, because flushing them
    /// mutates the collection being walked.
    var paths: [String] { Array(texts.keys) }

    var isEmpty: Bool { texts.isEmpty }

    /// Replaces whatever was waiting: with full-document sync the newest text
    /// subsumes every older one.
    mutating func stage(_ text: String, for path: String) {
        texts[path] = text
    }

    /// The waiting text, left where it is.
    func peek(_ path: String) -> String? { texts[path] }

    /// The waiting text, consumed — but only when there is a server to send
    /// it to.
    ///
    /// The condition is a parameter rather than something this value looks up
    /// itself, because the point is that the caller has already proved a
    /// server exists *before* the text leaves here. Consuming first and
    /// finding out afterwards that there was nowhere to send it is the bug
    /// this type was extracted from: every character typed while a server was
    /// still starting was thrown away.
    mutating func take(_ path: String, ifServerExists serverExists: Bool) -> String? {
        guard serverExists else { return nil }
        return texts.removeValue(forKey: path)
    }

    /// Drops the waiting text unsent. For a document that is closing: there
    /// is nobody left to be out of sync with.
    mutating func discard(_ path: String) {
        texts.removeValue(forKey: path)
    }
}

/// What a server said it can do for completion.
///
/// Read from the `capabilities` object `initialize` answered with — which was
/// stored and then never looked at by anything — and parsed once, at that
/// moment, into this. Not walked on demand: the typing path asks "is this
/// character a trigger" on every character, and that is not a question to
/// answer with three dictionary lookups and an array scan.
struct LSPCompletionCapability: Equatable, Sendable {
    /// The characters that make this server want to be asked, from
    /// `completionProvider.triggerCharacters`. Measured:
    /// `typescript-language-server` 5.3.0 sends `. " ' / @ <`, and
    /// `kotlin-language-server` 1.3.13 sends `.` alone.
    ///
    /// Only these count as a trigger. Sending `triggerKind: 2` for a
    /// character a server never advertised asks it to complete in a context
    /// it would have declined.
    let triggerCharacters: Set<Character>

    /// Whether `completionItem/resolve` is answered at all.
    ///
    /// Measured: true for `typescript-language-server` 5.3.0, where
    /// `asResolvedCompletionItem` is the *only* place documentation is ever
    /// set and `additionalTextEdits` arrive only from resolve — so without
    /// resolve there is neither a doc pane nor an auto-import. sourcekit-lsp
    /// answers resolve too, and its own log line says what for: "Retrieving
    /// documentation for completion item".
    ///
    /// False for `kotlin-language-server` 1.3.13, which sends
    /// `additionalTextEdits` inline and needs no resolve — **and which sends
    /// no per-item documentation either**. A documentation pane is therefore
    /// empty for Kotlin no matter what the client does. That is a fact about
    /// the server, not a bug worth re-investigating.
    let resolveProvider: Bool

    /// What a server that never mentioned completion supports. Distinct from
    /// nil, which means no server is running at all.
    static let none = LSPCompletionCapability(triggerCharacters: [], resolveProvider: false)

    init(triggerCharacters: Set<Character>, resolveProvider: Bool) {
        self.triggerCharacters = triggerCharacters
        self.resolveProvider = resolveProvider
    }

    /// - Parameter capabilities: the whole `capabilities` object from
    ///   `initialize`, not the `completionProvider` subtree — so that a
    ///   server which answered without a `completionProvider` parses to
    ///   `none` here rather than being mistaken for one that offers
    ///   everything.
    init(_ capabilities: LSPValue?) {
        let provider = capabilities?["completionProvider"]
        self.triggerCharacters = Set(
            (provider?["triggerCharacters"]?.arrayValue ?? []).compactMap { $0.stringValue?.first }
        )
        self.resolveProvider = provider?["resolveProvider"]?.boolValue ?? false
    }
}

extension LSPValue {
    /// A deep merge, with `other` winning leaf by leaf.
    ///
    /// Exists so a capability block can be composed from the transport's
    /// honest minimum plus what a feature adds, instead of one file editing
    /// the other's literal. Only objects merge — an array or a scalar on
    /// either side replaces outright, because a half-merged `valueSet` is a
    /// capability nobody wrote.
    func merging(_ other: LSPValue) -> LSPValue {
        guard case .object(let mine) = self, case .object(let theirs) = other else { return other }

        var merged = mine
        for (key, value) in theirs {
            merged[key] = mine[key]?.merging(value) ?? value
        }
        return .object(merged)
    }
}

/// One problem the server reported.
struct LSPDiagnostic: Identifiable, Equatable {
    enum Severity: Int, Equatable {
        case error = 1
        case warning = 2
        case information = 3
        case hint = 4
    }

    let range: LSPRange
    let severity: Severity
    let message: String
    let source: String?

    var id: String { "\(range.start.line):\(range.start.character):\(message)" }

    init?(_ value: LSPValue) {
        guard let range = LSPRange(value["range"]),
              let message = value["message"]?.stringValue
        else { return nil }

        self.range = range
        self.message = message
        self.source = value["source"]?.stringValue
        // Absent severity means "the server didn't say", and the
        // specification's advice is for the client to decide. Error is the
        // safe reading: a problem shown too loudly gets noticed, one shown
        // too quietly does not.
        self.severity = Severity(rawValue: value["severity"]?.intValue ?? 1) ?? .error
    }
}

/// A place in a file, for go-to-definition and references.
struct LSPLocation: Identifiable, Equatable {
    let uri: String
    let range: LSPRange

    var id: String { "\(uri):\(range.start.line):\(range.start.character)" }

    var path: String {
        URL(string: uri)?.path ?? uri.replacingOccurrences(of: "file://", with: "")
    }

    init?(_ value: LSPValue) {
        // A server may answer with `Location`, `LocationLink`, or an array
        // of either. The link form names the target differently, and a
        // client that only understands one of them silently does nothing
        // for half the servers out there.
        if let uri = value["uri"]?.stringValue, let range = LSPRange(value["range"]) {
            self.uri = uri
            self.range = range
            return
        }
        if let uri = value["targetUri"]?.stringValue,
           let range = LSPRange(value["targetSelectionRange"]) ?? LSPRange(value["targetRange"]) {
            self.uri = uri
            self.range = range
            return
        }
        return nil
    }
}

/// One edit the server wants applied.
struct LSPTextEdit: Equatable {
    let range: LSPRange
    let newText: String

    init?(_ value: LSPValue) {
        guard let range = LSPRange(value["range"]),
              let newText = value["newText"]?.stringValue
        else { return nil }
        self.range = range
        self.newText = newText
    }

    /// Applies edits to a string.
    ///
    /// **Back to front.** Every edit's range refers to the *original* text,
    /// so applying them in order invalidates every position after the first
    /// one. Sorting descending means each edit lands before anything that
    /// could have moved it — which is why servers are allowed to return
    /// them in any order at all.
    static func apply(_ edits: [LSPTextEdit], to text: String) -> String {
        let ns = NSMutableString(string: text)
        // One index for the whole batch: the ranges all refer to the
        // original text, so they can share it.
        let index = LSPLineIndex(ns)
        let ordered = edits.compactMap { edit -> (NSRange, String)? in
            guard let range = index.range(of: edit.range) else { return nil }
            return (range, edit.newText)
        }
        .sorted { $0.0.location > $1.0.location }

        for (range, replacement) in ordered {
            ns.replaceCharacters(in: range, with: replacement)
        }
        return ns as String
    }
}
