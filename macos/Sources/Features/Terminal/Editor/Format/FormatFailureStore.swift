import Foundation

/// The last formatting failure per file, kept so something other than one
/// view can read it.
///
/// A failed format used to live and die as `@State` in the pane that asked
/// for it: the sentence went into a notice, the notice faded, and nothing
/// held it afterwards. That is fine for a reader watching the pane and no
/// good for anyone who arrives later — the agent asked to fix the failure
/// most of all, since by the time it is asked the notice is gone.
///
/// Deliberately small. One entry per path, overwritten by the next attempt
/// and **cleared by the next success**, because a fixed file that keeps
/// reporting its old failure sends the reader — or the agent — after a
/// problem that is not there any more. Nothing here is persisted: a failure
/// describes the file as it was in this session, and a stale one restored
/// from disk would be worse than none.
@MainActor
final class FormatFailureStore {
    static let shared = FormatFailureStore()

    struct Failure: Equatable {
        let message: String
        let at: Date
    }

    /// Bounded so a session that formats thousands of files does not hold a
    /// sentence for each. The oldest go first, which is also the least
    /// interesting: a reader acts on what just failed.
    private static let limit = 200

    private var failures: [String: Failure] = [:]
    private var order: [String] = []

    private init() {}

    var all: [String: Failure] { failures }

    func failure(for path: String) -> Failure? { failures[path] }

    func record(_ message: String, for path: String, at date: Date = Date()) {
        if failures[path] == nil { order.append(path) }
        failures[path] = Failure(message: message, at: date)

        while order.count > Self.limit, let oldest = order.first {
            order.removeFirst()
            failures.removeValue(forKey: oldest)
        }
    }

    /// Called on every successful format, including one that changed
    /// nothing: both mean the formatter can read the file now.
    func clear(_ path: String) {
        guard failures.removeValue(forKey: path) != nil else { return }
        order.removeAll { $0 == path }
    }
}
