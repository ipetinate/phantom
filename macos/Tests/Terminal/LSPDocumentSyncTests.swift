import Foundation
@testable import Ghostty
import Testing

/// Keeping the server's copy of a document equal to the one on screen.
///
/// Nothing here goes near `LSPCenter.shared`: its `init` starts a
/// `DirectoryWatcher`, registers a `NotificationCenter` observer and kicks off
/// a login-shell probe, none of which belongs in a unit test. The bookkeeping
/// these bugs lived in was extracted into a value precisely so it could be
/// asserted without any of that.
@MainActor
struct LSPPendingChangeTests {
    /// Full-document sync means the newest text subsumes every older one, so
    /// staging twice must not leave two edits to send.
    @Test func stagingReplacesRatherThanQueues() {
        var pending = LSPPendingChanges()
        pending.stage("let a = 1", for: "/a.ts")
        pending.stage("let a = 12", for: "/a.ts")

        #expect(pending.peek("/a.ts") == "let a = 12")
        #expect(pending.take("/a.ts", ifServerExists: true) == "let a = 12")
        #expect(pending.isEmpty)
    }

    /// The bug: the text was consumed *before* the server lookup, so
    /// everything typed while a server was still starting was thrown away.
    /// Full sync hid it — the next keystroke resends the whole buffer — right
    /// up until the user stopped typing, which is when completion, hover and
    /// save ask their questions.
    @Test func textIsNotConsumedWhenThereIsNoServer() {
        var pending = LSPPendingChanges()
        pending.stage("let a = 1", for: "/a.ts")

        #expect(pending.take("/a.ts", ifServerExists: false) == nil)
        #expect(
            pending.peek("/a.ts") == "let a = 1",
            "text a starting server has not seen yet has to survive the failed flush"
        )
        #expect(!pending.isEmpty)
    }

    /// And once the server is up, the same text goes out — it was not merely
    /// kept, it is still sendable.
    @Test func theSurvivingTextIsSentOnceAServerExists() {
        var pending = LSPPendingChanges()
        pending.stage("let a = 1", for: "/a.ts")

        _ = pending.take("/a.ts", ifServerExists: false)
        #expect(pending.take("/a.ts", ifServerExists: true) == "let a = 1")
        #expect(pending.isEmpty)
    }

    @Test func peekLeavesItInPlace() {
        var pending = LSPPendingChanges()
        pending.stage("body", for: "/a.ts")

        #expect(pending.peek("/a.ts") == "body")
        #expect(pending.peek("/a.ts") == "body")
        #expect(!pending.isEmpty)
    }

    /// For a closing document: there is nobody left to be out of sync with,
    /// and a `didChange` for a URI the server was just told to forget is a
    /// protocol violation.
    @Test func discardDropsItUnsent() {
        var pending = LSPPendingChanges()
        pending.stage("body", for: "/a.ts")
        pending.discard("/a.ts")

        #expect(pending.peek("/a.ts") == nil)
        #expect(pending.take("/a.ts", ifServerExists: true) == nil)
    }

    @Test func nothingStagedTakesNothing() {
        var pending = LSPPendingChanges()
        #expect(pending.take("/never-opened.ts", ifServerExists: true) == nil)
        #expect(pending.isEmpty)
    }

    /// `paths` is a snapshot, because flushing a server's documents walks it
    /// while each flush removes an entry.
    @Test func pathsCanBeWalkedWhileTakingFromIt() {
        var pending = LSPPendingChanges()
        pending.stage("a", for: "/a.ts")
        pending.stage("b", for: "/b.ts")

        for path in pending.paths {
            _ = pending.take(path, ifServerExists: true)
        }
        #expect(pending.isEmpty)
    }
}

/// The four things `[]` used to mean.
struct LSPCompletionOutcomeTests {
    /// `.cancelled` is correctness rather than diagnostics: it says a newer
    /// request is already on its way, so the UI has to keep the list it is
    /// showing. A UI that only sees "no items" cannot tell that from an
    /// answer, and clears the list under the keystroke that was refining it.
    @Test func cancelledIsNotAnEmptyAnswer() {
        let cancelled = LSPCompletionOutcome.cancelled
        let answered = LSPCompletionOutcome.list(LSPCompletionList(items: []))

        #expect(cancelled != answered)
        #expect(cancelled.isCancelled)
        #expect(!answered.isCancelled)
        #expect(cancelled.items.isEmpty)
        #expect(answered.items.isEmpty)
    }

    @Test func everyFailureIsItsOwnCase() {
        let all: [LSPCompletionOutcome] = [
            .noServer,
            .cancelled,
            .timedOut,
            .failed("the server said no"),
            .list(LSPCompletionList(items: [])),
        ]
        #expect(Set(all.map { String(describing: $0) }).count == all.count)
    }
}

/// What finishing an item can end in.
struct LSPResolveOutcomeTests {
    private func item() throws -> LSPCompletion {
        try #require(LSPCompletion(["label": .string("useState")], index: 0, epoch: 1))
    }

    /// The two that would be lost by returning an optional, and both matter
    /// to what the pane draws: `.stale` means a newer list is on its way and
    /// the current text should stay, `.unsupported` means never ask again
    /// and draw no spinner.
    @Test func staleAndUnsupportedAreNotTheSameAsAnEmptyAnswer() throws {
        let resolved = LSPResolveOutcome.resolved(try item())

        #expect(LSPResolveOutcome.stale != LSPResolveOutcome.unsupported)
        #expect(LSPResolveOutcome.stale != resolved)
        #expect(LSPResolveOutcome.stale.item == nil)
        #expect(LSPResolveOutcome.unsupported.item == nil)
        #expect(LSPResolveOutcome.cancelled.item == nil)
        #expect(resolved.item?.label == "useState")
    }

    @Test func everyOutcomeIsItsOwnCase() throws {
        let all: [LSPResolveOutcome] = [
            .resolved(try item()),
            .stale,
            .unsupported,
            .noServer,
            .cancelled,
            .timedOut,
            .failed("boom"),
        ]
        #expect(Set(all.map { String(describing: $0) }).count == all.count)
    }
}

/// Prose from a server, and the kind it was written in.
struct LSPMarkupContentTests {
    /// The kind decides whether a renderer may run
    /// `CodeHoverInfo.split(markdown:)` over the text, so losing it is not
    /// cosmetic: that pass over plain text eats horizontal rules, reflows
    /// lines that meant to keep their breaks, and reads a row of backticks
    /// as a fence.
    @Test func aBareStringIsPlainText() {
        let content = LSPMarkupContent(.string("just words"))
        #expect(content?.kind == .plaintext)
        #expect(content?.value == "just words")
    }

    @Test func markupContentKeepsItsKind() {
        let markdown = LSPMarkupContent(["kind": .string("markdown"), "value": .string("# Title")])
        #expect(markdown?.kind == .markdown)
        #expect(markdown?.value == "# Title")

        let plain = LSPMarkupContent(["kind": .string("plaintext"), "value": .string("# Title")])
        #expect(plain?.kind == .plaintext)
    }

    /// Conservative on purpose: markdown drawn as plain text shows a few
    /// stray asterisks, while plain text run through a markdown splitter
    /// loses content.
    @Test func anUnknownKindIsReadAsPlainText() {
        #expect(LSPMarkupContent(["kind": .string("asciidoc"), "value": .string("x")])?.kind == .plaintext)
        #expect(LSPMarkupContent(["value": .string("x")])?.kind == .plaintext)
    }

    @Test func absentAndEmptyBothParseToNothing() {
        #expect(LSPMarkupContent(nil) == nil)
        #expect(LSPMarkupContent(.null) == nil)
        #expect(LSPMarkupContent(.string("")) == nil)
        #expect(LSPMarkupContent(["kind": .string("markdown"), "value": .string("")]) == nil)
    }
}

/// Which `CompletionContext` a keystroke earns.
struct LSPCompletionContextTests {
    /// Measured from `typescript-language-server` 5.3.0.
    private let typescript = LSPCompletionCapability(
        triggerCharacters: [".", "\"", "'", "/", "@", "<"],
        resolveProvider: true
    )

    /// Measured from `kotlin-language-server` 1.3.13.
    private let kotlin = LSPCompletionCapability(triggerCharacters: ["."], resolveProvider: false)

    @Test func aCharacterTheServerAdvertisedIsSentAsATrigger() {
        let context = LSPCompletionContext.decide(
            typedCharacter: ".",
            isRefiningIncompleteList: false,
            support: typescript
        )
        #expect(context.kind == .triggerCharacter)
        #expect(context.triggerCharacter == ".")
    }

    /// `@` is a trigger for TypeScript and not for Kotlin. Claiming a trigger
    /// a server never advertised asks it to complete in a context it would
    /// have declined.
    @Test func aCharacterTheServerNeverAdvertisedIsInvoked() {
        let context = LSPCompletionContext.decide(
            typedCharacter: "@",
            isRefiningIncompleteList: false,
            support: kotlin
        )
        #expect(context.kind == .invoked)
        #expect(context.triggerCharacter == nil)
    }

    /// The first request of a session the user opened by typing an identifier
    /// character is kind 1 — kind 3 is a statement about a list that is
    /// already on screen, and this one is not.
    @Test func typingAnIdentifierCharacterIsInvoked() {
        let context = LSPCompletionContext.decide(
            typedCharacter: "c",
            isRefiningIncompleteList: false,
            support: typescript
        )
        #expect(context.kind == .invoked)
    }

    @Test func reAskingForAnIncompleteListIsKindThree() {
        let context = LSPCompletionContext.decide(
            typedCharacter: "o",
            isRefiningIncompleteList: true,
            support: typescript
        )
        #expect(context.kind == .incomplete)
        #expect(context.triggerCharacter == nil)
    }

    /// A trigger character outranks refining an incomplete list: `.` starts a
    /// new session rather than narrowing the one on screen, and it is the
    /// piece of information the server can least afford to be denied.
    @Test func aTriggerCharacterOutranksAnIncompleteList() {
        let context = LSPCompletionContext.decide(
            typedCharacter: ".",
            isRefiningIncompleteList: true,
            support: typescript
        )
        #expect(context.kind == .triggerCharacter)
    }

    /// No server, no advertised set, so nothing can be a trigger.
    @Test func withoutAServerCapabilityNothingIsATrigger() {
        let context = LSPCompletionContext.decide(
            typedCharacter: ".",
            isRefiningIncompleteList: false,
            support: nil
        )
        #expect(context.kind == .invoked)
    }

    @Test func onlyATriggerCarriesACharacterOnTheWire() {
        #expect(LSPCompletionContext.invoked.value["triggerKind"]?.intValue == 1)
        #expect(LSPCompletionContext.invoked.value["triggerCharacter"] == nil)
        #expect(LSPCompletionContext.incomplete.value["triggerKind"]?.intValue == 3)
        #expect(LSPCompletionContext.incomplete.value["triggerCharacter"] == nil)

        let triggered = LSPCompletionContext.triggered(by: ".")
        #expect(triggered.value["triggerKind"]?.intValue == 2)
        #expect(triggered.value["triggerCharacter"]?.stringValue == ".")
    }
}

/// Reading `completionProvider` out of what `initialize` answered with.
///
/// Both fixtures are measured, and both matter: they are the two servers
/// whose behaviour the completion path is built around, and they disagree
/// about everything.
struct LSPCompletionCapabilityTests {
    /// `typescript-language-server` 5.3.0.
    private let typescript: LSPValue = [
        "hoverProvider": true,
        "completionProvider": [
            "triggerCharacters": [".", "\"", "'", "/", "@", "<"],
            "resolveProvider": true,
        ],
    ]

    /// `kotlin-language-server` 1.3.13.
    private let kotlin: LSPValue = [
        "completionProvider": [
            "triggerCharacters": ["."],
            "resolveProvider": false,
        ],
    ]

    @Test func typeScriptTriggersOnSixCharactersAndResolves() {
        let capability = LSPCompletionCapability(typescript)
        #expect(capability.triggerCharacters == Set<Character>([".", "\"", "'", "/", "@", "<"]))
        #expect(capability.resolveProvider)
    }

    /// The consequence this fixture exists for: Kotlin sends
    /// `additionalTextEdits` inline because it answers no resolve at all, so
    /// an auto-import path that requires resolve would work on TypeScript and
    /// silently do nothing here.
    @Test func kotlinTriggersOnlyOnDotAndResolvesNothing() {
        let capability = LSPCompletionCapability(kotlin)
        #expect(capability.triggerCharacters == Set<Character>(["."]))
        #expect(!capability.resolveProvider)
    }

    /// A server that answered without a `completionProvider` offers no
    /// completion — which is not the same as no server running, and is why
    /// the accessor is optional and this value is not.
    @Test func aServerWithoutACompletionProviderSupportsNothing() {
        #expect(LSPCompletionCapability(["hoverProvider": true]) == .none)
        #expect(LSPCompletionCapability(nil) == .none)
    }

    /// The spec says one character per entry; a server that sends more is
    /// read rather than dropped, and an empty string is dropped rather than
    /// becoming a trigger that matches nothing.
    @Test func oddTriggerEntriesAreToleratedRatherThanFatal() {
        let odd = LSPCompletionCapability([
            "completionProvider": ["triggerCharacters": ["::", "", "."]],
        ])
        #expect(odd.triggerCharacters == Set<Character>([":", "."]))
    }
}

/// What the client tells a server it can do.
///
/// Assembled in `LSPCenter` rather than in `LSPProcess`, so these assert the
/// merge as well as the block: the transport's honest minimum has to survive
/// having a completion block laid over it.
struct LSPClientCapabilityTests {
    private var completion: LSPValue? {
        LSPCenter.clientCapabilities["textDocument"]?["completion"]
    }

    private var item: LSPValue? { completion?["completionItem"] }

    @Test func theMergeKeepsEverythingTheTransportPromised() {
        let capabilities = LSPCenter.clientCapabilities
        #expect(capabilities["textDocument"]?["hover"]?["contentFormat"] != nil)
        #expect(capabilities["textDocument"]?["synchronization"]?["didSave"]?.boolValue == true)
        #expect(capabilities["textDocument"]?["rename"]?["prepareSupport"]?.boolValue == false)
        #expect(capabilities["workspace"]?["workspaceFolders"]?.boolValue == true)
    }

    /// The "origin" column: this is what makes `typescript-language-server`
    /// fill in `labelDetails.description` with the module a symbol comes from.
    @Test func theOriginColumnIsAskedFor() {
        #expect(item?["labelDetailsSupport"]?.boolValue == true)
    }

    /// On, now that the parser and the tab-stop session consume the marker.
    /// It was not merely cosmetic to leave off: measured,
    /// `typescript-language-server` does
    /// `if (isSnippet && !features.completionSnippets) return null`, so the
    /// old `false` dropped whole items rather than their placeholders.
    @Test func snippetSupportIsAnnounced() {
        #expect(item?["snippetSupport"]?.boolValue == true)
    }

    /// The claim above is a promise about *this* block, and the transport's
    /// own floor still says `false`. Both are correct and the overlay is what
    /// ships — so the merge direction is pinned here, because a `merging`
    /// that ever resolved a leaf the other way would quietly un-announce
    /// snippets and the only symptom would be missing suggestions.
    @Test func theOverlayWinsOverTheTransportsFloor() {
        let floor = LSPProcess.defaultCapabilities["textDocument"]?["completion"]
        #expect(floor?["completionItem"]?["snippetSupport"]?.boolValue == false)
        #expect(item?["snippetSupport"]?.boolValue == true)
    }

    /// Three capabilities that must not be claimed, each because claiming it
    /// fails invisibly: `insertReplaceSupport` and `commitCharactersSupport`
    /// promise behaviour the accept path does not have, and
    /// `completionList.itemDefaults` makes sourcekit-lsp stop sending a
    /// per-item edit at all.
    @Test func theCapabilitiesThatWouldBeLiesAreNotClaimed() {
        #expect(item?["insertReplaceSupport"]?.boolValue == false)
        #expect(item?["commitCharactersSupport"]?.boolValue == false)
        #expect(completion?["completionList"] == nil)
    }

    /// Exactly what `LSPCompletion.merging(resolved:)` takes from the reply,
    /// no more and no less — a property listed here that the merge would
    /// then discard is the same kind of lie as one nothing reads.
    @Test func resolveAsksOnlyForWhatIsRead() {
        let properties = item?["resolveSupport"]?["properties"]?
            .arrayValue?.compactMap(\.stringValue)
        #expect(properties == ["documentation", "detail", "additionalTextEdits", "command"])
    }

    @Test func everyItemKindIsAccepted() {
        let kinds = completion?["completionItemKind"]?["valueSet"]?
            .arrayValue?.compactMap(\.intValue)
        #expect(kinds == Array(1...25))
    }

    @Test func deprecationAndPreselectionAreAskedFor() {
        #expect(item?["deprecatedSupport"]?.boolValue == true)
        #expect(item?["preselectSupport"]?.boolValue == true)
        #expect(item?["tagSupport"]?["valueSet"]?.arrayValue?.compactMap(\.intValue) == [1])
    }
}

/// The deep merge the capability block is composed with.
struct LSPValueMergeTests {
    @Test func leavesAreReplacedAndSiblingsSurvive() {
        let base: LSPValue = ["a": ["x": 1, "y": 2], "b": 3]
        let merged = base.merging(["a": ["y": 9, "z": 10]])

        #expect(merged["a"]?["x"]?.intValue == 1)
        #expect(merged["a"]?["y"]?.intValue == 9)
        #expect(merged["a"]?["z"]?.intValue == 10)
        #expect(merged["b"]?.intValue == 3)
    }

    /// Arrays replace rather than merge: a half-merged `valueSet` is a
    /// capability nobody wrote.
    @Test func anArrayReplacesRatherThanMerges() {
        let base: LSPValue = ["valueSet": [1, 2, 3]]
        #expect(base.merging(["valueSet": [9]])["valueSet"]?.arrayValue?.compactMap(\.intValue) == [9])
    }

    @Test func aScalarOverAnObjectReplacesIt() {
        let base: LSPValue = ["completion": ["contextSupport": true]]
        #expect(base.merging(["completion": false])["completion"]?.boolValue == false)
    }
}

/// The notifications that used to be dropped on the floor.
struct LSPServerMessageTests {
    private func message(_ method: String, type: Int?, text: String) -> LSPNotification {
        var params: [String: LSPValue] = ["message": .string(text)]
        if let type { params["type"] = .integer(type) }
        return LSPNotification(method: method, params: .object(params))
    }

    /// The literal answer to "why are there no completions". The guard this
    /// replaced accepted `publishDiagnostics` and returned for everything
    /// else, so a server reporting its own failure through the protocol
    /// rather than stderr looked perfectly healthy while answering nothing.
    @Test func aCrashNoticeBecomesALogLine() {
        let lines = LSPCenter.logLines(
            from: message("window/logMessage", type: 1, text: "tsserver exited. Restarting…")
        )
        #expect(lines == ["[error] tsserver exited. Restarting…"])
    }

    @Test func everyMessageTypeHasItsOwnTag() {
        let tags = [1, 2, 3, 4, 5].map { type in
            LSPCenter.logLines(from: message("window/logMessage", type: type, text: "x")).first
        }
        #expect(tags == ["[error] x", "[warning] x", "[info] x", "[log] x", "[debug] x"])
    }

    /// Inventing a severity a server did not claim is how a log sheet ends up
    /// full of red that means nothing.
    @Test func anUntypedMessageIsALogLineRatherThanAnError() {
        #expect(LSPCenter.logLines(from: message("window/showMessage", type: nil, text: "x")) == ["[log] x"])
        #expect(LSPCenter.logLines(from: message("window/showMessage", type: 99, text: "x")) == ["[log] x"])
    }

    /// One entry per line, so a server's stack trace does not count as a
    /// single item against the ring's limit and push out two hundred real
    /// ones.
    @Test func aMultiLineMessageBecomesOneEntryPerLine() {
        let lines = LSPCenter.logLines(
            from: message(
                "window/showMessage",
                type: 2,
                text: "Could not resolve the Gradle classpath\nFalling back to an empty one"
            )
        )
        #expect(lines == [
            "[warning] Could not resolve the Gradle classpath",
            "[warning] Falling back to an empty one",
        ])
    }

    @Test func aNotificationWithoutAMessageProducesNothing() {
        #expect(LSPCenter.logLines(from: LSPNotification(method: "window/logMessage")).isEmpty)
        #expect(LSPCenter.logLines(from: message("window/logMessage", type: 1, text: "")).isEmpty)
    }
}
