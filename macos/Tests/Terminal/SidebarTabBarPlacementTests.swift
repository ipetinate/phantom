import Foundation
@testable import Ghostty
import Testing

struct SidebarTabBarPlacementTests {
    @Test func anAbsentValueIsTop() {
        #expect(SidebarTabBarPlacement(raw: nil) == .top)
    }

    @Test func anUnknownValueIsTop() {
        #expect(SidebarTabBarPlacement(raw: "left") == .top)
        #expect(SidebarTabBarPlacement(raw: "") == .top)
    }

    @Test func offersTopThenSide() {
        #expect(SidebarTabBarPlacement.allCases == [.top, .side])
    }

    @Test func everyPlacementRoundTripsThroughItsRawValue() {
        for placement in SidebarTabBarPlacement.allCases {
            #expect(SidebarTabBarPlacement(raw: placement.rawValue) == placement)
            #expect(SidebarTabBarPlacement(rawValue: placement.rawValue) == placement)
        }
    }

    @Test func theDefaultsKeyIsStable() {
        #expect(SidebarTabBarPlacement.defaultsKey == "SidebarTabBarPlacement")
    }
}
