import Foundation
@testable import Ghostty
import Testing

struct SurfaceVisibilityTests {
    @Test func aWindowTheWindowServerShowsIsVisible() {
        #expect(BaseTerminalController.surfaceTreeIsVisible(occlusionVisible: true, isKeyWindow: true))
        #expect(BaseTerminalController.surfaceTreeIsVisible(occlusionVisible: true, isKeyWindow: false))
    }

    @Test func theKeyWindowIsVisibleBeforeOcclusionCatchesUp() {
        #expect(BaseTerminalController.surfaceTreeIsVisible(occlusionVisible: false, isKeyWindow: true))
    }

    @Test func anOccludedWindowThatIsNotKeyIsHidden() {
        #expect(!BaseTerminalController.surfaceTreeIsVisible(occlusionVisible: false, isKeyWindow: false))
    }
}
