import Testing

@testable import Ghostty

/// The tab menu, which exists twice — as SwiftUI buttons for the right click
/// and as an `NSMenu` for the double click — and is therefore described once.
struct EditorTabCommandTests {
    @Test func everyCommandIsNamed() {
        for command in EditorTabCommand.allCases {
            #expect(!command.title.isEmpty)
        }
    }

    /// Closing others needs others. With one tab open the command would close
    /// nothing, and an item that does nothing is worse than an absent one.
    @Test func aLoneTabIsNotOfferedCloseOthers() {
        let alone = EditorTabCommand.menu(hasSiblings: false)
        #expect(!alone.contains(.command(.closeOthers)))
        #expect(alone.contains(.command(.close)))
        #expect(alone.contains(.command(.closeAll)))
    }

    @Test func aTabWithSiblingsIsOfferedEverything() {
        let menu = EditorTabCommand.menu(hasSiblings: true)
        for command in EditorTabCommand.allCases {
            #expect(menu.contains(.command(command)), "\(command.title) is missing")
        }
    }

    /// A separator falls where the group changes and nowhere else, so a menu
    /// can never open or close on a rule, or show two in a row.
    @Test func theRulesFallBetweenRunsOnly() {
        for hasSiblings in [true, false] {
            let menu = EditorTabCommand.menu(hasSiblings: hasSiblings)

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
