import Foundation
@testable import Ghostty
import Testing

struct ExtensionViewerMessageTests {
    @Test func readyCarriesTheViewersVersion() {
        #expect(ExtensionViewerMessage.parse(["type": "ready", "version": "0.3.0"]) == .ready(version: "0.3.0"))
        #expect(ExtensionViewerMessage.parse(["type": "ready", "version": "v0.3"]) == nil)
        #expect(ExtensionViewerMessage.parse(["type": "ready"]) == nil)
        #expect(ExtensionViewerMessage.parse(["type": "ready", "version": 3]) == nil)
    }

    @Test func renderedCarriesItsWarningsEscaped() {
        #expect(ExtensionViewerMessage.parse(["type": "rendered"]) == .rendered(warnings: []))
        #expect(ExtensionViewerMessage.parse(["type": "rendered", "warnings": []]) == .rendered(warnings: []))
        #expect(
            ExtensionViewerMessage.parse(["type": "rendered", "warnings": ["unknown component <Foo>", 3, "", "bidi\u{202E}"]])
                == .rendered(warnings: ["unknown component <Foo>", "bidi\\u{202E}"]))

        let many = ExtensionViewerMessage.parse(["type": "rendered", "warnings": Array(repeating: "w", count: 100)])
        #expect(many == .rendered(warnings: Array(repeating: "w", count: ExtensionViewerMessage.maxWarnings)))
    }

    @Test func failedCarriesAMessageAndAnOptionalPosition() {
        #expect(
            ExtensionViewerMessage.parse(["type": "failed", "message": "Unexpected token", "line": 12, "column": 4])
                == .failed(message: "Unexpected token", line: 12, column: 4))
        #expect(
            ExtensionViewerMessage.parse(["type": "failed", "message": "Unexpected token"])
                == .failed(message: "Unexpected token", line: nil, column: nil))
        #expect(
            ExtensionViewerMessage.parse(["type": "failed", "message": "Unexpected token", "line": -1, "column": "4"])
                == .failed(message: "Unexpected token", line: nil, column: nil))
        #expect(ExtensionViewerMessage.parse(["type": "failed"]) == nil)
        #expect(ExtensionViewerMessage.parse(["type": "failed", "message": ""]) == nil)

        let hostile = ExtensionViewerMessage.parse(["type": "failed", "message": "line\nbreak\u{202E}"])
        guard case .failed(let message, _, _)? = hostile else {
            Issue.record("expected a failure")
            return
        }
        #expect(!message.contains("\n"))
        #expect(!message.unicodeScalars.contains("\u{202E}"))

        let long = ExtensionViewerMessage.parse(["type": "failed", "message": String(repeating: "x", count: 2000)])
        guard case .failed(let capped, _, _)? = long else {
            Issue.record("expected a failure")
            return
        }
        #expect(capped.count == ExtensionViewerMessage.maxMessageLength)
    }

    @Test func copyCarriesTheTextUntouchedAndRefusesEmptyOrHuge() {
        #expect(ExtensionViewerMessage.parse(["type": "copy", "text": "brew install stylua\n"]) == .copy("brew install stylua\n"))
        #expect(ExtensionViewerMessage.parse(["type": "copy", "text": ""]) == nil)
        #expect(ExtensionViewerMessage.parse(["type": "copy", "text": 7]) == nil)
        #expect(ExtensionViewerMessage.parse(["type": "copy", "text": String(repeating: "x", count: ExtensionViewerMessage.maxCopyLength + 1)]) == nil)
    }

    @Test func openAcceptsOnlyHTTPSAndMail() {
        #expect(
            ExtensionViewerMessage.parse(["type": "open", "href": "https://example.com/docs"])
                == .open(URL(string: "https://example.com/docs")!))
        #expect(
            ExtensionViewerMessage.parse(["type": "open", "href": "mailto:someone@example.com"])
                == .open(URL(string: "mailto:someone@example.com")!))

        for href in ["http://example.com", "file:///etc/passwd", "javascript:alert(1)", "ftp://x.y", "mailto:",
                     "https:relative", "", "https://exa\u{202E}mple.com", "x-phantom://open"] {
            #expect(ExtensionViewerMessage.parse(["type": "open", "href": href]) == nil, "\(href)")
        }
        #expect(ExtensionViewerMessage.parse(["type": "open"]) == nil)
        #expect(ExtensionViewerMessage.parse(["type": "open", "href": 7]) == nil)
    }

    @Test func anythingElseIsNoMessage() {
        #expect(ExtensionViewerMessage.parse("ready") == nil)
        #expect(ExtensionViewerMessage.parse(["ready"]) == nil)
        #expect(ExtensionViewerMessage.parse(7) == nil)
        #expect(ExtensionViewerMessage.parse(NSNull()) == nil)
        #expect(ExtensionViewerMessage.parse([String: Any]()) == nil)
        #expect(ExtensionViewerMessage.parse(["type": "eval", "code": "1+1"]) == nil)
        #expect(ExtensionViewerMessage.parse(["type": 1]) == nil)
        #expect(ExtensionViewerMessage.parse(["type": "READY", "version": "0.3.0"]) == nil)
    }
}
