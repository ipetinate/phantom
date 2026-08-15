import Foundation

/// A value, or the sentence explaining why there isn't one.
///
/// `Result`'s `Failure` is constrained to `Error`, which a plain
/// user-facing reason has no business satisfying — wrapping every message
/// in an `Error` type just to unwrap it two lines later at the call site
/// would be ceremony with nothing behind it.
enum LSPOutcome<Success> {
    case success(Success)
    case failure(String)
}

/// What is true about one language server right now, for the (language,
/// workspace root) pair it runs under.
///
/// Before this, the only signal exposed to the UI was whether a server's
/// binary was on `PATH`. That answers "would this even start", not "is it
/// working", and collapsing the two into one flag is why installing
/// Kotlin's server made the "not installed" banner disappear while hover
/// kept saying nothing: the binary being found and the server actually
/// answering requests are different facts, and only one of them was
/// visible.
enum LSPServerStatus: Equatable, Sendable {
    /// The registry (or an override) names a server for this language, and
    /// its binary isn't on the login `PATH`.
    case notInstalled

    /// Spawned; the `initialize` handshake is in flight.
    case starting

    /// `initialize` answered and `initialized` was sent. Whether a specific
    /// feature is offered is a separate question — see
    /// `LSPCenter.hasCapability(_:forPath:)`.
    case running

    /// The process never reached `running` — it failed to launch, or
    /// `initialize` threw. Distinct from `crashed`: this server never did
    /// anything.
    case failedToStart(reason: String)

    /// The process exited after having run for a while.
    case crashed(status: Int32?)

    /// Running, but the last several requests all timed out. The server is
    /// there and the pipe is open; something in it has stopped answering.
    case unresponsive

    /// Whether this is worth telling a person about. `starting` and
    /// `running` are what a healthy server looks like and would just be
    /// noise in a banner.
    var isFailure: Bool {
        switch self {
        case .notInstalled, .failedToStart, .crashed, .unresponsive: return true
        case .starting, .running: return false
        }
    }

    /// One clause for a banner or a message — the log, where there is one,
    /// is shown separately rather than folded in here.
    var summary: String {
        switch self {
        case .notInstalled: return "isn't installed"
        case .starting: return "is starting"
        case .running: return "is running"
        case .failedToStart(let reason): return "didn't start: \(reason)"
        case .crashed(let status):
            return "exited" + (status.map { " (status \($0))" } ?? "")
        case .unresponsive: return "stopped responding"
        }
    }
}

/// Aggregated status for a server binary across all workspaces currently
/// known to Phantom. Settings has no single file path to use, so this is the
/// truthful status surface for the server list.
struct LSPServerStatusSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case unknown
        case notInstalled
        case installed
        case starting
        case running
        case error(String)
    }

    let state: State
    let activeWorkspaceCount: Int

    var label: String {
        switch state {
        case .unknown: return "Unknown"
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        case .starting: return "Starting"
        case .running: return activeWorkspaceCount > 0 ? "Running" : "Installed"
        case .error: return "Error"
        }
    }

    var systemImage: String {
        switch state {
        case .unknown: return "questionmark.circle"
        case .notInstalled: return "circle.dashed"
        case .installed: return "checkmark.circle"
        case .starting: return "circle.dotted.and.circle"
        case .running: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}
