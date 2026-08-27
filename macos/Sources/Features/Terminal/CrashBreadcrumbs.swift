import AppKit
import Foundation

/// Writes down why the process is about to die, for the cases macOS does not.
///
/// ## Why this exists
///
/// The app was reported to have quit mid-typing, with the completion list and
/// its documentation card open. There was nothing to investigate with:
///
/// - No `.ips` in `~/Library/Logs/DiagnosticReports`, so not an abort, not a
///   `precondition`, not an array index — those all leave one.
/// - No memory-pressure event and no spindump.
/// - The executable had not been replaced under the running process.
/// - `WindowGhostRescue`'s own log simply stopped, with no `willTerminate`
///   line — so `applicationWillTerminate` never ran, which rules out ⌘Q and
///   anything else that goes through AppKit.
///
/// That combination leaves an uncaught Objective-C exception that AppKit
/// swallowed, or a signal. Neither leaves a trace today, and the absence of a
/// trace is what made the report unactionable. So both are recorded, into the
/// log that already survives the process.
///
/// ## What it cannot catch
///
/// `SIGKILL`, by definition — Force Quit, `kill -9`, or the kernel. If a death
/// leaves nothing here either, that is itself the finding: it narrows the cause
/// to the one class of exit no process can observe.
///
/// Development builds only, like the log it writes to.
enum CrashBreadcrumbs {
    /// The signals worth a line. `SIGKILL` and `SIGSTOP` are absent because
    /// they cannot be handled, and the others here are the ones a crash in
    /// AppKit or in our own code arrives as.
    private static let watched: [Int32] = [
        SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGFPE, SIGTRAP, SIGTERM,
    ]

    /// Arms both handlers. Idempotent, and safe to call before the UI exists.
    static func install() {
        guard DevelopmentBuild.isActive else { return }

        NSSetUncaughtExceptionHandler { exception in
            /// The reason and the call stack, on one line each so the tail of
            /// the log stays readable. `callStackSymbols` is already resolved
            /// by the runtime — there is nothing to symbolicate afterwards.
            WindowBreadcrumbs.note("UNCAUGHT EXCEPTION: \(exception.name.rawValue): "
                + (exception.reason ?? "no reason"))
            for frame in exception.callStackSymbols.prefix(24) {
                WindowBreadcrumbs.note("  \(frame)")
            }
        }

        for signal in watched { arm(signal) }
    }

    /// Records the signal and then dies of it.
    ///
    /// Re-raised rather than returned from, and the default handler restored
    /// first: swallowing a fatal signal would leave the process alive in a
    /// state its own code has already decided is impossible, which is worse
    /// than the crash. Restoring the default is also what lets macOS write the
    /// `.ips` it would have written anyway.
    ///
    /// Only `signal-safe` work happens here — one string, one write. The
    /// note goes through the same serial queue the rest of the log uses.
    private static func arm(_ number: Int32) {
        signal(number) { received in
            WindowBreadcrumbs.note("FATAL SIGNAL \(received) (\(Self.name(of: received)))")
            signal(received, SIG_DFL)
            raise(received)
        }
    }

    private static func name(of signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGILL: return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        case SIGTERM: return "SIGTERM"
        default: return "unknown"
        }
    }
}
