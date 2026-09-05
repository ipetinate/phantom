import Foundation

struct LSPWorkDoneProgress: Equatable, Sendable {
    let token: String
    var title: String
    var message: String?
    var percentage: Int?
    var updatedAt: Date
}

struct LSPProgressLedger: Equatable, Sendable {
    static let staleAfter: TimeInterval = 60
    static let method = "$/progress"

    private(set) var active: [String: LSPWorkDoneProgress] = [:]

    var current: LSPWorkDoneProgress? {
        active.values.max { $0.updatedAt < $1.updatedAt }
    }

    mutating func apply(_ notification: LSPNotification, now: Date) {
        guard notification.method == Self.method,
              let token = Self.token(in: notification.params?["token"]),
              let value = notification.params?["value"],
              let kind = value["kind"]?.stringValue
        else { return }

        let message = value["message"]?.stringValue
        let percentage = value["percentage"]?.intValue

        switch kind {
        case "begin":
            guard let title = value["title"]?.stringValue,
                  !Self.reportsNothingToDo(message)
            else { return }
            active[token] = LSPWorkDoneProgress(
                token: token,
                title: title,
                message: message,
                percentage: percentage,
                updatedAt: now
            )

        case "report":
            guard var progress = active[token] else { return }
            if Self.reportsNothingToDo(message) {
                active.removeValue(forKey: token)
                return
            }
            if let message { progress.message = message }
            if let percentage { progress.percentage = percentage }
            progress.updatedAt = now
            active[token] = progress

        case "end":
            active.removeValue(forKey: token)

        default:
            return
        }
    }

    mutating func prune(now: Date) {
        active = active.filter { now.timeIntervalSince($0.value.updatedAt) < Self.staleAfter }
    }

    static func token(in value: LSPValue?) -> String? {
        value?.stringValue ?? value?.intValue.map(String.init)
    }

    static func reportsNothingToDo(_ message: String?) -> Bool {
        message?.range(of: #"^0\s*/\s*0$"#, options: .regularExpression) != nil
    }
}
