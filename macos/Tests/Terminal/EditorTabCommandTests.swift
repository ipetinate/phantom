import AppKit
import Testing

@testable import Ghostty

/// The tab menu, which exists twice — as a right-click and as a double click —
/// and is therefore described once.
@MainActor
struct EditorTabCommandTests {
    private func availability(
        hasSiblings: Bool = true,
        canSplitOut: Bool = true,
        canReturnToMainPane: Bool = true
    ) -> EditorTabCommand.Availability {
        EditorTabCommand.Availability(
            hasSiblings: hasSiblings,
            canSplitOut: canSplitOut,
            canReturnToMainPane: canReturnToMainPane)
    }

    @Test func everyCommandIsNamed() {
        for command in EditorTabCommand.allCases {
            #expect(!command.title.isEmpty)
        }
    }

    /// An icon this build cannot draw is not an error — it is a menu item with
    /// a hole where its glyph should be, which is why the names are asserted
    /// rather than trusted.
    @Test func everyIconResolves() {
        for command in EditorTabCommand.allCases {
            let image = NSImage(systemSymbolName: command.icon, accessibilityDescription: nil)
            #expect(image != nil, "\(command.icon) is not a symbol this build has")
        }
    }

    /// Closing others needs others. With one tab open the command would close
    /// nothing, and an item that does nothing is worse than an absent one.
    @Test func aLoneTabIsNotOfferedCloseOthers() {
        let menu = EditorTabCommand.menu(availability(hasSiblings: false))
        #expect(!menu.contains(.command(.closeOthers)))
        #expect(menu.contains(.command(.close)))
        #expect(menu.contains(.command(.closeAll)))
    }

    /// A tab whose cell would heal straight back is not offered a split: the
    /// tree divides the cell, moves the tab across, finds the half it left
    /// empty and removes it again.
    @Test func aTabThatCannotDivideIsNotOfferedSplits() {
        let menu = EditorTabCommand.menu(availability(canSplitOut: false))

        for command in EditorTabCommand.allCases where command.zone != nil {
            #expect(!menu.contains(.command(command)), "\(command.title) should be absent")
        }
    }

    @Test func aTabAlreadyInTheMainPaneIsNotOfferedTheWayBack() {
        let menu = EditorTabCommand.menu(availability(canReturnToMainPane: false))
        #expect(!menu.contains(.command(.moveToMainPane)))
    }

    @Test func aTabWithEverythingAvailableIsOfferedEverything() {
        let menu = EditorTabCommand.menu(availability())
        for command in EditorTabCommand.allCases {
            #expect(menu.contains(.command(command)), "\(command.title) is missing")
        }
    }

    /// The four splits carry the four edges, and each edge exactly once —
    /// a copied line that left two commands pointing the same way would
    /// otherwise be invisible.
    @Test func theFourSplitsCoverTheFourEdges() {
        let zones = EditorTabCommand.allCases.compactMap(\.zone)
        #expect(Set(zones) == Set([.leading, .trailing, .top, .bottom]))
        #expect(zones.count == 4)
    }

    /// A separator falls where the group changes and nowhere else, so a menu
    /// can never open or close on a rule, or show two in a row.
    @Test func theRulesFallBetweenRunsOnly() {
        let cases = [
            availability(),
            availability(hasSiblings: false),
            availability(canSplitOut: false),
            availability(canReturnToMainPane: false),
            availability(hasSiblings: false, canSplitOut: false, canReturnToMainPane: false),
        ]

        for availability in cases {
            let menu = EditorTabCommand.menu(availability)

            #expect(menu.first != .separator)
            #expect(menu.last != .separator)

            for (index, entry) in menu.enumerated() where entry == .separator {
                #expect(menu[index - 1] != .separator, "two rules in a row")
            }

            let rules = menu.filter { $0 == .separator }.count
            let groups = Set(menu.compactMap { entry -> Int? in
                guard case .command(let command) = entry else { return nil }
                return command.group
            })
            #expect(rules == groups.count - 1)
        }
    }
}
