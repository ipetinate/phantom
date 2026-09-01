import Foundation

/// One package-manager command, running, with its output on screen.
///
/// The shape `LanguageServersSettingsView` has been installing language servers
/// with: the login shell so a version manager's `npm` is on `PATH`, the output
/// streamed rather than collected, and a percentage parsed out of it when the
/// manager prints one. This is that, extracted, so the welcome panel is a second
/// caller instead of a second copy — the settings form keeps its own until
/// somebody has a reason to touch it, and then the change is a deletion.
///
/// **Every command that reaches here is a compiled-in literal.** The language
/// servers' come from `LSPServerRegistry`, the agents' from
/// `AgentInstallPlan`, and neither is assembled from anything a file on disk
/// said. Nothing here quotes or escapes, because nothing here is given
/// somebody else's string to run.
@MainActor
final class PackageInstallRun: ObservableObject {
    /// What is running, if anything. `nil` is also what a finished run leaves
    /// behind — the result is in ``failure`` and ``output``.
    @Published private(set) var command: String?

    /// The tail of what the command has printed. Bounded: this is a progress
    /// indicator, not a log, and a `brew install` prints thousands of lines.
    @Published private(set) var output: [String] = []

    /// Why the last run failed, or nil when it worked or has not run.
    @Published private(set) var failure: String?

    var isRunning: Bool { command != nil }

    /// The last four lines, which is what fits under a card without pushing
    /// the button it belongs to off the screen.
    var recentOutput: [String] { Array(output.suffix(4)) }

    /// The percentage the manager last printed, if it printed one.
    ///
    /// npm and Homebrew both print a running percentage; before the first one
    /// arrives there is nothing to fill a determinate bar with, and the caller
    /// shows a spinner instead. Read from the end, because the last number is
    /// the current one.
    var progress: Double? {
        for line in output.reversed() {
            guard let match = line.firstMatch(of: /(\d+(?:\.\d+)?)\s*%/),
                  let value = Double(match.output.1)
            else { continue }
            return min(max(value / 100.0, 0), 1)
        }
        return nil
    }

    /// How many lines of output are kept.
    private static let keptLines = 12

    /// Longer than the language-server form's 300s, and stated rather than
    /// inherited: a cold `brew install --cask` downloads an application, and a
    /// run killed at the deadline is reported as a failure with no way to
    /// resume — so the number has to be one that a slow network does not reach.
    ///
    /// `ShellCommand.runStreaming` gives the child `/dev/null` on stdin, so a
    /// command that decides to ask a question fails rather than hanging here
    /// forever. No command in `AgentInstallPlan` needs `sudo`, which is the
    /// one that would.
    static let timeout: TimeInterval = 900

    /// Runs a command and returns whether it succeeded.
    ///
    /// - Parameter onFinish: called on the main actor with the result, after
    ///   ``command`` is cleared, so a caller can re-probe what is now installed.
    func run(_ command: String, onFinish: @escaping (Bool) -> Void = { _ in }) {
        guard !isRunning else { return }

        self.command = command
        failure = nil
        output = []

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        Task { [weak self] in
            let environment = await Task.detached(priority: .userInitiated) {
                LoginEnvironment.executableEnvironment()
            }.value

            let result = await Task.detached(priority: .userInitiated) {
                ShellCommand.runStreaming(
                    shell,
                    ["-lic", command],
                    environment: environment,
                    timeout: Self.timeout
                ) { line in
                    Task { @MainActor in self?.append(line) }
                }
            }.value

            guard let self else { return }
            self.command = nil
            if !result.succeeded { self.failure = result.message }
            onFinish(result.succeeded)
        }
    }

    private func append(_ line: String) {
        output.append(line)
        if output.count > Self.keptLines {
            output.removeFirst(output.count - Self.keptLines)
        }
    }
}
