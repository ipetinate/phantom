import AppKit
import Foundation
import Testing

@testable import Ghostty

/// The sheet, minus the window.
///
/// Everything asserted here is a rule about what the reader is offered and
/// what happens when they answer nothing at all. The sheet itself needs a
/// window and a person, but these three do not, and they are the ones that
/// decide whether a distracted answer costs a scrollback.
@MainActor
struct MCPPermissionPromptTests {
    private let tab = UUID()

    private func request(
        _ capability: MCPPermission.Capability = .read,
        surface: UUID? = nil,
        group: String? = nil
    ) -> MCPPermission.Request {
        MCPPermission.Request(capability: capability, surface: surface, group: group)
    }

    // MARK: What is offered

    /// Narrow to wide, so the first segment — the one the picker opens on — is
    /// always the least the reader can give away.
    @Test func theScopesAreOfferedNarrowestFirst() {
        let offered = MCPPermissionPrompt.scopes(for: request(surface: tab, group: "work"))
        #expect(offered == [.tab, .group, .all])
    }

    /// A `group` grant with nothing to anchor it matches nothing, forever. The
    /// reader would press "Always Allow" and be asked again on the very next
    /// call, which is worse than not being offered the choice.
    @Test func aQuestionWithNoGroupDoesNotOfferOne() {
        #expect(MCPPermissionPrompt.scopes(for: request(surface: tab)) == [.tab, .all])
    }

    @Test func aQuestionWithNoTabDoesNotOfferOne() {
        #expect(MCPPermissionPrompt.scopes(for: request(group: "work")) == [.group, .all])
    }

    /// `all` needs no anchor, so there is always something to say yes to.
    @Test func thereIsAlwaysAtLeastOneScope() {
        #expect(MCPPermissionPrompt.scopes(for: request()) == [.all])
    }

    /// The first segment is what "Always Allow" grants when the reader never
    /// touches the picker. It must never be `all`, unless `all` is the only
    /// honest answer.
    @Test func theNarrowestOfferIsNeverEverythingWhenSomethingSmallerFits() {
        #expect(MCPPermissionPrompt.scopes(for: request(surface: tab)).first == .tab)
        #expect(MCPPermissionPrompt.scopes(for: request(group: "work")).first == .group)
    }

    // MARK: What an answer means

    @Test func theFirstButtonGrantsForThisCallOnly() {
        #expect(MCPPermissionPrompt.answer(for: .alertFirstButtonReturn) == .grant(always: false))
    }

    @Test func theSecondButtonGrantsForGood() {
        #expect(MCPPermissionPrompt.answer(for: .alertSecondButtonReturn) == .grant(always: true))
    }

    @Test func theThirdButtonRefuses() {
        #expect(MCPPermissionPrompt.answer(for: .alertThirdButtonReturn) == .refuse)
    }

    /// The one that matters. A sheet can end without anyone pressing a button
    /// — the window it hangs on closes, or the app is asked to stop — and the
    /// response then is none of the three above. A question that ends without
    /// an answer has to end as a refusal: the store holds one at a time, so an
    /// unanswered one would deny every later call in silence.
    @Test(arguments: [
        NSApplication.ModalResponse.cancel,
        .stop,
        .abort,
        .continue,
        .OK,
    ])
    func anythingElseRefuses(_ response: NSApplication.ModalResponse) {
        #expect(MCPPermissionPrompt.answer(for: response) == .refuse)
    }

    // MARK: What it says

    @Test func everyScopeHasAWordTheReaderCanAct() {
        for scope in MCPPermission.Scope.allCases {
            #expect(!MCPPermissionPrompt.label(for: scope).isEmpty)
        }
        #expect(MCPPermissionPrompt.label(for: .all) == "All Terminals")
    }

    /// The two capabilities are risky for different reasons, and the sheet has
    /// to say which one this is — a reader who reads "scrollback" under a
    /// question about running commands learns the sheet is boilerplate.
    @Test func theStakesNameTheCapability() {
        #expect(MCPPermissionPrompt.informative(for: .read).contains("Scrollback"))
        #expect(MCPPermissionPrompt.informative(for: .run).contains("Commands"))
    }

    @Test func bothStakesSayWhereToRevoke() {
        for capability in MCPPermission.Capability.allCases {
            #expect(MCPPermissionPrompt.informative(for: capability).contains("Settings"))
        }
    }
}

/// A grant, once it is a row somebody reads months after answering.
struct MCPGrantPhraseTests {
    private let tab = UUID()

    private func grant(
        _ capability: MCPPermission.Capability = .read,
        _ scope: MCPPermission.Scope,
        surface: UUID? = nil,
        group: String? = nil
    ) -> MCPPermission.Grant {
        MCPPermission.Grant(
            capability: capability, scope: scope, surface: surface, group: group)
    }

    @Test func theCapabilityIsSaidAsAnAction() {
        #expect(MCPGrantPhrase.capability(.read) == "Read scrollback")
        #expect(MCPGrantPhrase.capability(.run) == "Run commands")
    }

    @Test func aTabGrantNamesTheTab() {
        let phrase = MCPGrantPhrase.reach(
            grant(.read, .tab, surface: tab), tab: "build", group: nil)
        #expect(phrase == "In \u{201C}build\u{201D}")
    }

    @Test func aGroupGrantNamesTheGroup() {
        let phrase = MCPGrantPhrase.reach(
            grant(.run, .group, surface: tab, group: "work"), tab: "build", group: "Work")
        #expect(phrase == "In every terminal in \u{201C}Work\u{201D}")
    }

    /// `all` names nothing, because there is nothing to name — and it must not
    /// borrow the tab it happened to be granted from.
    @Test func theWidestGrantNamesNoTab() {
        let phrase = MCPGrantPhrase.reach(grant(.read, .all), tab: "build", group: "Work")
        #expect(phrase == "In every terminal")
    }

    /// A grant outlives the tab it was made from, and the row stays in the
    /// list. Saying so is what lets the reader tell the dead row from three
    /// live ones that would otherwise read identically.
    @Test func aGrantForAClosedTabSaysSo() {
        let phrase = MCPGrantPhrase.reach(
            grant(.read, .tab, surface: tab), tab: nil, group: nil)
        #expect(phrase == "In a terminal that is no longer open")
    }

    @Test func aGroupGrantWithNoGroupSaysSo() {
        let phrase = MCPGrantPhrase.reach(grant(.read, .group), tab: nil, group: nil)
        #expect(phrase == "In a group that is no longer recorded")
    }
}
