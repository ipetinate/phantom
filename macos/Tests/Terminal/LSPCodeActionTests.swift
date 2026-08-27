import Foundation
@testable import Ghostty
import Testing

/// What a server offers to do at a position, and the shapes it offers it in.
///
/// The payloads below came off a live `typescript-language-server` 5.3.0
/// driving TypeScript 5.9.3 over a real project, not from the specification:
/// the specification allows several shapes and says nothing about which ones
/// servers actually send, and the ones they send are the ones a client has
/// to read.
struct LSPCodeActionTests {
    /// The rich `CodeAction` form, which is what a server sends once the
    /// client claims `codeActionLiteralSupport`.
    private let quickFix: LSPValue = [
        "title": .string("Remove unused declaration for: 'probe'"),
        "kind": .string("quickfix"),
        "isPreferred": .bool(true),
        "edit": [
            "documentChanges": .array([[
                "textDocument": ["uri": .string("file:///w/models.ts"), "version": .integer(1)],
                "edits": .array([[
                    "range": [
                        "start": ["line": .integer(41), "character": .integer(0)],
                        "end": ["line": .integer(42), "character": .integer(0)],
                    ],
                    "newText": .string(""),
                ]]),
            ]]),
        ],
        "command": [
            "title": .string("Remove unused declaration for: 'probe'"),
            "command": .string("_typescript.applyCodeActionCommand"),
            "arguments": .array([["fixName": .string("unusedIdentifier")]]),
        ],
    ]

    /// The pre-3.8 bare `Command`, still sent by `jdtls` and
    /// `kotlin-language-server`: `command` is the name itself, not an object.
    private let bareCommand: LSPValue = [
        "title": .string("Organize imports"),
        "command": .string("kotlin.organizeImports"),
        "arguments": .array([.string("file:///w/Main.kt")]),
    ]

    @Test func theRichFormIsReadWhole() throws {
        let action = try #require(LSPCodeAction(quickFix, index: 3, origin: "typescript-language-server"))

        #expect(action.id == 3)
        #expect(action.title == "Remove unused declaration for: 'probe'")
        #expect(action.kind == "quickfix")
        #expect(action.isPreferred)
        #expect(action.disabledReason == nil)
        #expect(action.origin == "typescript-language-server")
        #expect(action.edit["/w/models.ts"]?.count == 1)
    }

    /// Measured: a real quick fix arrives with an edit **and** a command.
    /// Reading it as one or the other applies half of what the reader chose.
    @Test func anActionCanCarryBothAnEditAndACommand() throws {
        let action = try #require(LSPCodeAction(quickFix))

        #expect(!action.edit.isEmpty)
        #expect(action.command?.command == "_typescript.applyCodeActionCommand")
        #expect(action.hasWork)
    }

    /// The bare form. Read its `command` as the rich form's object and a
    /// server's whole menu comes back titled and inert.
    @Test func theBareCommandFormIsReadAsAnInvocation() throws {
        let action = try #require(LSPCodeAction(bareCommand))

        #expect(action.title == "Organize imports")
        #expect(action.edit.isEmpty)
        #expect(action.command?.command == "kotlin.organizeImports")
        #expect(action.command?.arguments == [.string("file:///w/Main.kt")])
        #expect(action.hasWork)
        #expect(!action.needsResolve, "a bare command carries its work; there is nothing to resolve")
    }

    @Test func aDisabledActionKeepsItsReasonAndIsNotApplicable() throws {
        let action = try #require(LSPCodeAction([
            "title": .string("Extract to function"),
            "kind": .string("refactor.extract"),
            "disabled": ["reason": .string("Selection spans a return statement")],
        ]))

        #expect(action.disabledReason == "Selection spans a return statement")
        #expect(!action.isApplicable)
    }

    @Test func anEntryWithoutATitleIsRefused() {
        #expect(LSPCodeAction(["kind": .string("quickfix")]) == nil)
    }

    // MARK: Resolve

    /// Only an action with nothing to do, on a server that can fill it in.
    @Test func needsResolveRequiresBothEmptinessAndTheCapability() throws {
        let empty: LSPValue = ["title": .string("Organize Imports"), "kind": .string("source.organizeImports")]

        #expect(try #require(LSPCodeAction(empty, canResolve: true)).needsResolve)
        #expect(try !#require(LSPCodeAction(empty, canResolve: false)).needsResolve)
        #expect(try !#require(LSPCodeAction(quickFix, canResolve: true)).needsResolve)
    }

    /// A resolve fills in the work and nothing else. Letting it change the
    /// title would rewrite a menu the reader is already looking at.
    @Test func resolveTakesTheWorkAndLeavesTheIdentity() throws {
        let action = try #require(LSPCodeAction([
            "title": .string("Organize Imports"),
            "kind": .string("source.organizeImports"),
        ], index: 2, canResolve: true))

        let resolved = action.merging(resolved: [
            "title": .string("Something else entirely"),
            "kind": .string("quickfix"),
            "edit": [
                "changes": [
                    "file:///w/models.ts": .array([[
                        "range": [
                            "start": ["line": .integer(0), "character": .integer(0)],
                            "end": ["line": .integer(0), "character": .integer(0)],
                        ],
                        "newText": .string("import x\n"),
                    ]]),
                ],
            ],
        ])

        #expect(resolved.title == "Organize Imports")
        #expect(resolved.kind == "source.organizeImports")
        #expect(resolved.id == 2)
        #expect(resolved.edit["/w/models.ts"]?.first?.newText == "import x\n")
        #expect(!resolved.needsResolve)
    }

    /// A server that answers a resolve with nothing leaves the action as it
    /// was — still unresolved, so a caller can tell it apart from one that
    /// genuinely has no work.
    @Test func anEmptyResolveDoesNotClearWhatWasThere() throws {
        let action = try #require(LSPCodeAction(quickFix))
        let resolved = action.merging(resolved: .null)

        #expect(!resolved.edit.isEmpty)
        #expect(resolved.command?.command == "_typescript.applyCodeActionCommand")
    }

    // MARK: Merging

    @Test func listParsingNumbersInOrderAndToleratesNull() {
        let list = LSPCodeAction.list(from: .array([quickFix, bareCommand]), origin: "gopls")

        #expect(list.map(\.id) == [0, 1])
        #expect(list.allSatisfy { $0.origin == "gopls" })
        #expect(LSPCodeAction.list(from: .null).isEmpty)
    }

    /// Two servers' menus become one, in order, with the ids renumbered
    /// against the merged list rather than each server's slice of it.
    @Test func mergingConcatenatesAndRenumbers() throws {
        let vue = LSPCodeAction.list(from: .array([bareCommand]), origin: "vue-language-server")
        let script = LSPCodeAction.list(from: .array([quickFix]), origin: "typescript-language-server")

        let merged = LSPCodeAction.merged([vue, script])

        #expect(merged.map(\.id) == [0, 1])
        #expect(merged[0].origin == "vue-language-server")
        #expect(merged[1].origin == "typescript-language-server")
    }

    /// Deduped on title *and* kind. Two servers describing the same fix is
    /// one entry; the same words under two kinds is two behaviours.
    @Test func mergingDedupesOnTitleAndKindTogether() {
        let shared: LSPValue = ["title": .string("Add all missing imports"), "kind": .string("quickfix")]
        let sourceKind: LSPValue = ["title": .string("Add all missing imports"), "kind": .string("source")]

        let first = LSPCodeAction.list(from: .array([shared, sourceKind]), origin: "a")
        let second = LSPCodeAction.list(from: .array([shared]), origin: "b")

        let merged = LSPCodeAction.merged([first, second])
        #expect(merged.count == 2)
        #expect(merged.map(\.kind) == ["quickfix", "source"])
        #expect(merged.allSatisfy { $0.origin == "a" }, "first occurrence wins, whole")
    }

    // MARK: What travels with the request

    /// The field quick fixes live or die on. Measured on
    /// `typescript-language-server`: the same position with the server's own
    /// diagnostics answers 18 actions of which 1 is a quick fix; with those
    /// diagnostics re-encoded without their `code`, 17 actions and **no**
    /// quick fix at all. The request succeeds either way.
    @Test func theContextCarriesTheDiagnosticsVerbatim() throws {
        let raw: LSPValue = [
            "range": [
                "start": ["line": .integer(41), "character": .integer(13)],
                "end": ["line": .integer(41), "character": .integer(31)],
            ],
            "severity": .integer(1),
            "code": .integer(2304),
            "source": .string("typescript"),
            "message": .string("Cannot find name 'RefundDenialReason'."),
        ]

        let context = LSPCodeAction.context(diagnostics: [raw])
        let sent = try #require(context["diagnostics"]?.arrayValue)

        #expect(sent.count == 1)
        #expect(sent[0]["code"] == .integer(2304), "the code is what a fix is matched on")
        #expect(sent[0] == raw, "verbatim, not re-encoded")
    }

    // MARK: Capabilities

    /// `codeActionProvider` is a plain `true` on several servers. Read only
    /// the object form and their whole menu is skipped.
    @Test func aBooleanProviderIsDeclaredWithoutResolve() {
        let capability = LSPCodeActionCapability(["codeActionProvider": .bool(true)])

        #expect(capability.isDeclared)
        #expect(capability.isWorthAsking)
        #expect(!capability.resolveProvider)
    }

    @Test func anObjectProviderCarriesItsResolveFlag() {
        let with = LSPCodeActionCapability(["codeActionProvider": ["resolveProvider": .bool(true)]])
        #expect(with.isDeclared)
        #expect(with.resolveProvider)

        let without = LSPCodeActionCapability(["codeActionProvider": ["codeActionKinds": .array([])]])
        #expect(without.isDeclared)
        #expect(!without.resolveProvider)
    }

    /// Only an explicit `false` is a refusal.
    @Test func onlyAnExplicitNoIsARefusal() {
        #expect(LSPCodeActionCapability(["codeActionProvider": .bool(false)]).isRefused)
        #expect(!LSPCodeActionCapability(["codeActionProvider": .bool(false)]).isWorthAsking)
    }

    /// Silence is not a refusal. A server that declared nothing may register
    /// the feature later through `client/registerCapability`, which this
    /// client acknowledges without recording — so reading absence as "no"
    /// would skip that server for the rest of the session.
    @Test func silenceIsNotARefusalAndIsStillAsked() {
        #expect(!LSPCodeActionCapability(nil).isDeclared)
        #expect(LSPCodeActionCapability(nil).isWorthAsking)
        #expect(LSPCodeActionCapability(["hoverProvider": .bool(true)]).isWorthAsking)
    }

    @Test func theAdvertisedCommandsAreRead() {
        let capability: LSPValue = [
            "executeCommandProvider": [
                "commands": .array([.string("_typescript.applyCodeActionCommand"), .string("_typescript.organizeImports")]),
            ],
        ]

        #expect(LSPCodeAction.executeCommands(in: capability).contains("_typescript.organizeImports"))
        #expect(LSPCodeAction.executeCommands(in: nil).isEmpty)
    }

    // MARK: What this client claims

    /// The claim that makes servers send the rich form at all. Without it
    /// they must fall back to bare commands, and the menu loses its kinds,
    /// its preferred action and every previewable edit.
    @Test func theClientClaimsCodeActionLiterals() throws {
        let claimed = LSPCenter.clientCapabilities["textDocument"]?["codeAction"]
        let kinds = try #require(
            claimed?["codeActionLiteralSupport"]?["codeActionKind"]?["valueSet"]?.arrayValue
        )

        #expect(kinds.contains(.string("quickfix")))
        #expect(kinds.contains(.string("source.organizeImports")))
        #expect(
            kinds.contains(.string("")),
            """
            The empty kind is the protocol's way of saying "and the ones this \
            client has not heard of". Measured: typescript-language-server \
            sends source.organizeImports.ts, which no fixed list would have.
            """
        )
        #expect(claimed?["disabledSupport"] == .bool(true))
        #expect(claimed?["dataSupport"] == .bool(true))
    }

    /// Only what `LSPCodeAction.merging(resolved:)` actually takes. A
    /// property claimed here is a promise that its absence from the first
    /// answer is fine.
    @Test func theClientResolvesOnlyWhatItReads() throws {
        let properties = try #require(
            LSPCenter.clientCapabilities["textDocument"]?["codeAction"]?["resolveSupport"]?["properties"]?
                .arrayValue
        )

        #expect(Set(properties) == [.string("edit"), .string("command")])
    }

    /// Claimed only because it is now answered. A server told `true` by a
    /// client that then refuses the request runs the action and has its
    /// result dropped.
    @Test func theClientClaimsApplyEditAndAnswersIt() {
        #expect(LSPCenter.clientCapabilities["workspace"]?["applyEdit"] == .bool(true))
        #expect(LSPCenter.applyEditResult(applied: true) == ["applied": .bool(true)])
        #expect(LSPCenter.applyEditResult(applied: false) == ["applied": .bool(false)])
    }

    /// The transport still refuses what it does not understand, so adding a
    /// handler for one request did not turn every unknown one into a
    /// silent success.
    @Test func thePlainTransportStillRefusesWhatItCannotAnswer() {
        let unknown = LSPRequest(id: .number(1), method: "workspace/applyEdit")
        switch LSPProcess.defaultAnswer(to: unknown) {
        case .success: Issue.record("the bare transport claimed to apply an edit")
        case .failure: break
        }

        let housekeeping = LSPRequest(id: .number(2), method: "client/registerCapability")
        switch LSPProcess.defaultAnswer(to: housekeeping) {
        case .success(let value): #expect(value == .null)
        case .failure: Issue.record("a handshake request went unanswered")
        }
    }

    // MARK: Routing

    /// Actions route the same way completion items do, through the same
    /// helper, because the failure they avoid is the same one.
    @Test func anActionGoesBackToTheServerThatOfferedIt() {
        let commands = ["vue-language-server", "typescript-language-server"]

        #expect(
            LSPCenter.resolvingCommand(origin: "typescript-language-server", among: commands)
                == "typescript-language-server"
        )
        #expect(LSPCenter.resolvingCommand(origin: nil, among: commands) == "vue-language-server")
        #expect(LSPCenter.resolvingCommand(origin: "gopls", among: commands) == "vue-language-server")
        #expect(LSPCenter.resolvingCommand(origin: "gopls", among: []) == nil)
    }
}
