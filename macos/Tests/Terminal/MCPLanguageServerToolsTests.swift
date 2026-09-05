import Foundation
@testable import Ghostty
import Testing

/// The two tools that act on a language server.
///
/// Scope worth stating: restarting one really restarts it, and the cooldown
/// clock is private to the enum, so neither is driven from here. What is
/// covered is everything that decides *whether* and *what* — naming a server,
/// the refusals, and the sentence the reader is asked to approve.
@MainActor
struct MCPLanguageServerToolsTests {
    // MARK: What is on offer

    @Test func theToolsAreRestartAndConfigure() {
        let names = MCPLanguageServerTools.all.map(\.tool.name)
        #expect(names == ["restart_language_server", "configure_language_server"])
    }

    @Test func theyReachTheClientThroughTheRegistry() {
        let registered = Set(MCPToolRegistry.all.map(\.tool.name))
        for handler in MCPLanguageServerTools.all {
            #expect(registered.contains(handler.tool.name))
        }
    }

    @Test func eachNamesWhatItCannotDoWithout() {
        let required = MCPLanguageServerTools.all.reduce(into: [String: [JSONValue]]()) {
            $0[$1.tool.name] = $1.tool.schema.object?["required"]?.array
        }

        #expect(required["restart_language_server"] == [.string("server")])
        #expect(
            required["configure_language_server"]
                == [.string("server"), .string("initialization_options")])
    }

    /// The description is what decides whether a tool is reached for at the
    /// right moment, and this one has a consequence a caller must know before
    /// it calls: the setting is not scoped to the project it is working in.
    @Test func configureSaysItAppliesEverywhere() {
        let handler = MCPLanguageServerTools.all.first {
            $0.tool.name == "configure_language_server"
        }!

        #expect(handler.tool.description.contains("every project"))
    }

    @Test func restartSaysHowOftenItMayBeCalled() {
        let handler = MCPLanguageServerTools.all.first {
            $0.tool.name == "restart_language_server"
        }!

        #expect(handler.tool.description.contains("per minute"))
    }

    // MARK: Naming a server

    /// Both spellings, because `list_language_servers` reports both and a
    /// model handed two strings will use either.
    @Test func aServerIsFoundByItsNameOrItsCommand() throws {
        let known = try #require(LSPServerRegistry.distinctServers.first)

        #expect(MCPLanguageServerTools.server(known.displayName)?.command == known.command)
        #expect(MCPLanguageServerTools.server(known.command)?.command == known.command)
    }

    /// The name is prose in the interface. Refusing it over a capital letter
    /// would be a refusal about nothing.
    @Test func theNameIsMatchedWithoutRegardForCase() throws {
        let known = try #require(LSPServerRegistry.distinctServers.first)

        #expect(
            MCPLanguageServerTools.server(known.displayName.uppercased())?.command
                == known.command)
    }

    @Test func anUnknownNameIsNotFound() {
        #expect(MCPLanguageServerTools.server("not-a-server-anybody-has") == nil)
    }

    private var contributedLua: LSPServerDefinition {
        LSPServerDefinition(
            languageID: "lua",
            displayName: "Lua (acme)",
            command: "lua-language-server",
            arguments: ["--stdio"],
            installHint: "brew install lua-language-server",
            origin: .manifest(ExtensionProvenance(
                extensionID: "acme.lua",
                digest: "0",
                manifestPath: "/Users/x/.config/phantom/extensions/acme.lua/extension.json",
                scope: .user
            ))
        )
    }

    @Test func aContributedServerIsFoundByNameCommandOrLanguageID() throws {
        let builtIn = try #require(LSPServerRegistry.distinctServers.first)
        let servers = MCPLanguageServerTools.knownServers(
            builtIn: [builtIn], contributed: [contributedLua]
        )

        #expect(MCPLanguageServerTools.server("Lua (acme)", among: servers) == contributedLua)
        #expect(MCPLanguageServerTools.server("lua-language-server", among: servers) == contributedLua)
        #expect(MCPLanguageServerTools.server("LUA", among: servers) == contributedLua)
        #expect(MCPLanguageServerTools.server(builtIn.languageID, among: servers) == builtIn)
    }

    @Test func theNameWinsOverALanguageIDThatSpellsTheSame() {
        let named = LSPServerDefinition(
            languageID: "python", displayName: "lua", command: "pyright-langserver",
            arguments: [], installHint: ""
        )
        let servers = MCPLanguageServerTools.knownServers(builtIn: [named], contributed: [contributedLua])

        #expect(MCPLanguageServerTools.server("lua", among: servers) == named)
    }

    @Test func oneCommandIsListedOnce() {
        let twin = LSPServerDefinition(
            languageID: "lua", displayName: "Lua", command: "lua-language-server",
            arguments: [], installHint: ""
        )
        let servers = MCPLanguageServerTools.knownServers(builtIn: [twin], contributed: [contributedLua])

        #expect(servers == [twin])
    }

    @Test func theListingSaysWhereEachServerCameFrom() throws {
        let builtIn = try #require(LSPServerRegistry.distinctServers.first)

        #expect(MCPLanguageServerTools.origin(of: builtIn) == "built-in")
        #expect(MCPLanguageServerTools.origin(of: contributedLua) == "extension:acme.lua")
    }

    @Test func theRefusalNamesContributedServersToo() {
        let reason = MCPLanguageServerTools.unknownServer("nonsense", among: [contributedLua])

        #expect(reason.contains("Lua (acme)"))
    }

    /// A refusal that only says "no such server" leaves the caller guessing at
    /// spellings, so it lists what there is.
    @Test func theRefusalNamesTheServersThatExist() throws {
        let known = try #require(LSPServerRegistry.distinctServers.first)

        let reason = MCPLanguageServerTools.unknownServer("nonsense")

        #expect(reason.contains("list_language_servers"))
        #expect(reason.contains(known.displayName))
    }

    // MARK: What the reader is asked to approve

    /// Both sides of the change. "Set initializationOptions" says nothing
    /// about what is being replaced.
    @Test func theQuestionShowsWhatItIsNowAndWhatItWouldBecome() throws {
        let known = try #require(LSPServerRegistry.distinctServers.first)

        let sentence = MCPLanguageServerTools.diff(known, to: "{\"plugins\":[]}")

        #expect(sentence.contains(known.displayName))
        #expect(sentence.contains("Now:"))
        #expect(sentence.contains("Proposed:"))
        #expect(sentence.contains("{\"plugins\":[]}"))
    }

    /// Going back to the default is a change too, and reads as harmless until
    /// you know the default is what made Vue work.
    @Test func goingBackToTheDefaultIsSaidInWords() throws {
        let known = try #require(LSPServerRegistry.distinctServers.first)

        let sentence = MCPLanguageServerTools.diff(known, to: "")

        #expect(sentence.contains("this app's own default"))
    }

    // MARK: The third capability

    @Test func configureIsItsOwnCapability() {
        #expect(MCPPermission.Capability.configure.title.contains("language server"))
        #expect(MCPPermission.Capability.allCases.contains(.configure))
    }

    /// A grant to type into a shell must not carry a grant to rewrite the
    /// app's configuration.
    @Test func aGrantToRunDoesNotAnswerARequestToConfigure() {
        let tab = UUID()
        let run = MCPPermission.Grant(capability: .run, scope: .all, surface: nil, group: nil)

        let asked = MCPPermission.Request(capability: .configure, surface: tab, group: nil)

        #expect(MCPPermission.isAllowed(asked, by: [run]) == false)
    }

    @Test func aGrantToConfigureAnswersOne() {
        let tab = UUID()
        let grant = MCPPermission.Grant(
            capability: .configure, scope: .tab, surface: tab, group: nil)

        let asked = MCPPermission.Request(capability: .configure, surface: tab, group: nil)

        #expect(MCPPermission.isAllowed(asked, by: [grant]))
    }

    /// The reach in the sheet is about who may ask again, not about what the
    /// change touches, so the stakes have to say the change is app-wide.
    @Test func theStakesSayTheChangeIsNotLocal() {
        let text = MCPPermissionPrompt.informative(for: .configure)

        #expect(text.contains("every project"))
        #expect(text.contains("Settings"))
    }

    /// Read months later by somebody who does not remember answering.
    @Test func theRevokeListNamesWhatWasAllowed() {
        #expect(MCPGrantPhrase.capability(.configure).contains("language server"))
    }
}
