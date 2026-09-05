import Foundation

struct LSPServerWarning: Equatable, Sendable {
    static let method = "window/showMessage"
    static let staleAfter: TimeInterval = 300
    static let maxLength = 400

    let text: String
    let isError: Bool
    let at: Date

    func isStale(now: Date) -> Bool {
        now.timeIntervalSince(at) > Self.staleAfter
    }

    static func make(from notification: LSPNotification, now: Date) -> LSPServerWarning? {
        guard notification.method == method,
              let type = notification.params?["type"]?.intValue,
              type == 1 || type == 2,
              let message = notification.params?["message"]?.stringValue
        else { return nil }

        let text = message
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return LSPServerWarning(text: String(text.prefix(maxLength)), isError: type == 1, at: now)
    }
}
