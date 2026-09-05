import Foundation
@testable import Ghostty
import Testing

struct LSPServerWarningTests {
    private func notification(type: Int?, message: String?, method: String = LSPServerWarning.method) -> LSPNotification {
        var params: [String: LSPValue] = [:]
        if let type { params["type"] = .integer(type) }
        if let message { params["message"] = .string(message) }
        return LSPNotification(method: method, params: params)
    }

    @Test func onlyAnErrorOrAWarningReachesTheReader() {
        let now = Date()
        #expect(LSPServerWarning.make(from: notification(type: 1, message: "Boom"), now: now)?.isError == true)
        #expect(LSPServerWarning.make(from: notification(type: 2, message: "Careful"), now: now)?.isError == false)
        for type in [3, 4, 5] {
            #expect(LSPServerWarning.make(from: notification(type: type, message: "Chatter"), now: now) == nil)
        }
        #expect(LSPServerWarning.make(from: notification(type: nil, message: "Chatter"), now: now) == nil)
        #expect(LSPServerWarning.make(from: notification(type: 2, message: nil), now: now) == nil)
        #expect(LSPServerWarning.make(from: notification(type: 2, message: "   "), now: now) == nil)
    }

    @Test func aLogMessageIsNotAWarning() {
        let sent = notification(type: 1, message: "Boom", method: "window/logMessage")
        #expect(LSPServerWarning.make(from: sent, now: Date()) == nil)
    }

    @Test func theTextIsOneLineAndBounded() {
        let long = String(repeating: "x", count: LSPServerWarning.maxLength + 40)
        let made = LSPServerWarning.make(from: notification(type: 2, message: "More than\n100000 files"), now: Date())
        #expect(made?.text == "More than 100000 files")
        #expect(LSPServerWarning.make(from: notification(type: 2, message: long), now: Date())?.text.count == LSPServerWarning.maxLength)
    }

    @Test func aWarningGoesQuietOnItsOwn() {
        let warning = LSPServerWarning(text: "Boom", isError: false, at: Date())
        #expect(!warning.isStale(now: warning.at.addingTimeInterval(LSPServerWarning.staleAfter - 1)))
        #expect(warning.isStale(now: warning.at.addingTimeInterval(LSPServerWarning.staleAfter + 1)))
    }
}
