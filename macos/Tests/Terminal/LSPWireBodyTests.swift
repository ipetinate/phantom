import Foundation
@testable import Ghostty
import Testing

/// What a body means once its framing was right — and which bodies are worth
/// reading at all.
///
/// `LSPMessageTests` covers the framing. This file covers the two things that
/// changed underneath it: bodies are parsed with `JSONSerialization` rather
/// than `JSONDecoder`, and a reply nobody is waiting for is dropped before
/// its payload is ever converted.
struct LSPWireBodyTests {
    private func framed(_ body: String) -> Data {
        let payload = Data(body.utf8)
        var data = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        data.append(payload)
        return data
    }

    private func methods(_ results: [Result<LSPMessage, LSPFramingError>]) -> [String] {
        results.compactMap { result in
            guard case .success(let message) = result else { return nil }
            switch message {
            case .notification(let notification): return notification.method
            case .request(let request): return request.method
            case .response: return "<response>"
            }
        }
    }

    private func responses(_ results: [Result<LSPMessage, LSPFramingError>]) -> [LSPResponse] {
        results.compactMap { result in
            guard case .success(.response(let response)) = result else { return nil }
            return response
        }
    }

    // MARK: The reply nobody wants

    /// The measurement behind this: `tailwindcss-language-server` answers a
    /// completion inside a `class` attribute with 23,632 items — 5.4 MB — and
    /// does **not** honour `$/cancelRequest`. Five keystrokes produced five
    /// full answers to four questions already withdrawn, each of which the
    /// decoder converted in full on the one queue the next answer was queued
    /// behind. The list stopped appearing at all rather than merely late.
    @Test func aReplyNobodyIsWaitingForIsNotDecoded() {
        let decoder = LSPMessageDecoder()
        var stream = framed(#"{"jsonrpc":"2.0","id":1,"result":{"items":["abandoned"]}}"#)
        stream.append(framed(#"{"jsonrpc":"2.0","id":2,"result":{"items":["wanted"]}}"#))

        let results = decoder.append(stream, wantsResponse: { $0 == .number(2) })

        #expect(responses(results).map(\.id) == [.number(2)], "\(responses(results).map(\.id))")
        #expect(decoder.pendingByteCount == 0)
    }

    /// Dropping one must not desynchronise the stream: its bytes are consumed
    /// like any other message's, so whatever came behind it still arrives.
    @Test func theMessageBehindAnAbandonedReplyStillArrives() {
        let decoder = LSPMessageDecoder()
        var stream = framed(#"{"jsonrpc":"2.0","id":1,"result":{"a":1}}"#)
        stream.append(framed(#"{"jsonrpc":"2.0","method":"after"}"#))

        let results = decoder.append(stream, wantsResponse: { _ in false })

        #expect(methods(results) == ["after"], "\(methods(results))")
        #expect(decoder.pendingByteCount == 0)
    }

    /// Only replies are gated. A server's own request has to be answered
    /// whatever the client is waiting for — one that goes unanswered is a
    /// server that stops serving — and a notification is nobody's reply.
    @Test func requestsAndNotificationsAreNeverGated() {
        let decoder = LSPMessageDecoder()
        var stream = framed(#"{"jsonrpc":"2.0","id":1,"method":"workspace/configuration","params":{}}"#)
        stream.append(framed(#"{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics"}"#))

        let results = decoder.append(stream, wantsResponse: { _ in false })

        #expect(
            methods(results) == ["workspace/configuration", "textDocument/publishDiagnostics"],
            "\(methods(results))"
        )
    }

    /// A reply whose id is null correlates with nothing, so there is nobody to
    /// ask about it. It goes through and is dropped later, where it can be
    /// logged.
    @Test func aReplyWithNoIdIsNotGated() {
        let decoder = LSPMessageDecoder()
        let stream = framed(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"bad"}}"#)

        let results = decoder.append(stream, wantsResponse: { _ in false })

        #expect(responses(results).count == 1, "\(responses(results).count)")
    }

    /// The default is what the transport did before there was a gate, so a
    /// caller with no notion of pending requests keeps every message.
    @Test func everythingIsWantedWhenNobodySaysOtherwise() {
        let decoder = LSPMessageDecoder()

        let results = decoder.append(framed(#"{"jsonrpc":"2.0","id":9,"result":true}"#))

        #expect(responses(results).map(\.result) == [.bool(true)])
    }

    /// Gating happens after framing, so it cannot depend on where a read
    /// landed: the id is only known once the whole body is in the buffer.
    @Test func aReplySplitAcrossReadsIsStillGatedCorrectly() {
        let decoder = LSPMessageDecoder()
        let whole = framed(#"{"jsonrpc":"2.0","id":4,"result":{"a":1}}"#)

        let head = decoder.append(whole.prefix(whole.count - 5), wantsResponse: { _ in false })
        let tail = decoder.append(whole.suffix(5), wantsResponse: { _ in false })

        #expect(head.isEmpty)
        #expect(tail.isEmpty, "\(tail.count)")
        #expect(decoder.pendingByteCount == 0)
    }

    // MARK: What the body parses to

    /// `true` and `1` are both `NSNumber` by the time `JSONSerialization` is
    /// done with them, and `1` casts to `Bool` as happily as `true` does. The
    /// wrong answer here turns every `line: 1` into `line: true`.
    @Test func trueIsNotOneAndOneIsNotTrue() throws {
        let message = try LSPMessage.decode(
            body: Data(#"{"jsonrpc":"2.0","method":"m","params":{"t":true,"f":false,"one":1,"zero":0}}"#.utf8)
        )

        guard case .notification(let notification) = message else {
            Issue.record("expected a notification, got \(message)")
            return
        }
        #expect(notification.params?["t"] == .bool(true))
        #expect(notification.params?["f"] == .bool(false))
        #expect(notification.params?["one"] == .integer(1))
        #expect(notification.params?["zero"] == .integer(0))
    }

    /// Int before Double, which is the ordering `LSPValue`'s `Codable`
    /// conformance documents and the reason offsets survive a round trip as
    /// integers. `JSONSerialization` reports `2.0` and `1e3` as doubles, so
    /// the rule is applied rather than inherited.
    @Test func aWholeNumberIsAnIntegerHoweverItIsSpelled() throws {
        let message = try LSPMessage.decode(
            body: Data(#"{"jsonrpc":"2.0","method":"m","params":{"a":2.0,"b":1e3,"c":1.5}}"#.utf8)
        )

        guard case .notification(let notification) = message else {
            Issue.record("expected a notification, got \(message)")
            return
        }
        #expect(notification.params?["a"] == .integer(2))
        #expect(notification.params?["b"] == .integer(1000))
        #expect(notification.params?["c"] == .double(1.5))
    }

    /// `"result": null` is a *successful* answer — it is what `shutdown`
    /// returns — and an absent result alongside an error is a different
    /// message. Collapsing the two loses the difference.
    @Test func aNullResultIsNotAnAbsentOne() throws {
        let nulled = try LSPMessage.decode(body: Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8))
        let absent = try LSPMessage.decode(
            body: Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"no"}}"#.utf8)
        )

        guard case .response(let first) = nulled, case .response(let second) = absent else {
            Issue.record("expected two responses, got \(nulled) and \(absent)")
            return
        }
        #expect(first.result == LSPValue.null)
        #expect(second.result == nil)
        #expect(second.error?.code == -32601)
    }

    /// An error object missing its own fields is refused rather than read as
    /// "no error": that would turn a failed request into a successful one
    /// carrying nothing, which the caller cannot tell from a server with
    /// nothing to say.
    @Test func anErrorObjectWithoutCodeAndMessageIsRefused() {
        #expect(throws: (any Error).self) {
            try LSPMessage.decode(body: Data(#"{"jsonrpc":"2.0","id":1,"error":{"nope":true}}"#.utf8))
        }
    }

    /// A body that is not a JSON object is not a JSON-RPC message, whatever
    /// else it parses as.
    @Test func aBodyThatIsNotAnObjectIsRefused() {
        #expect(throws: (any Error).self) { try LSPMessage.decode(body: Data("[1,2]".utf8)) }
        #expect(throws: (any Error).self) { try LSPMessage.decode(body: Data("12".utf8)) }
        #expect(throws: (any Error).self) { try LSPMessage.decode(body: Data("not json".utf8)) }
    }

    /// A string id survives as a string: some servers use them, and a reply
    /// keyed `"7"` does not answer the request keyed `7`.
    @Test func aStringIdIsNotANumber() throws {
        let message = try LSPMessage.decode(body: Data(#"{"jsonrpc":"2.0","id":"7","result":1}"#.utf8))

        guard case .response(let response) = message else {
            Issue.record("expected a response, got \(message)")
            return
        }
        #expect(response.id == .string("7"))
    }

    /// Round-tripping is what `completionItem/resolve` does with an item: the
    /// server is sent back the object it sent, so anything the parse mangles
    /// comes back to it wrong.
    @Test func aBodySurvivesBeingParsedAndEncodedAgain() throws {
        let item = #"{"label":"flex","kind":9,"deprecated":false,"score":1.5,"#
            + #""data":{"_projectKey":"0"},"textEdit":{"newText":"flex","#
            + #""range":{"start":{"line":1,"character":25},"end":{"line":1,"character":29}}}}"#
        let json = #"{"jsonrpc":"2.0","id":3,"result":{"items":["# + item + #"],"isIncomplete":false}}"#

        let message = try LSPMessage.decode(body: Data(json.utf8))
        let again = try LSPMessage.decode(body: try message.encodedBody())

        #expect(message == again)
    }
}
