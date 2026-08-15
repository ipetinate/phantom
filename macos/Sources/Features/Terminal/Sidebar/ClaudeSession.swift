import AppKit

/// Starting a Claude Code session inside a terminal surface — both for a
/// tab opened from the sidebar and for one resuming after a restore.
enum ClaudeSession {
    /// How long to keep polling for the shell before giving up. If the
    /// shell isn't running in the foreground within this window the
    /// command is dropped rather than injected into a dead surface.
    private static let shellWaitTimeout: TimeInterval = 10.0

    /// How often to poll the surface for the shell's arrival.
    private static let shellPollInterval: TimeInterval = 0.05

    static func commandLine(for command: String) -> String {
        "\(command)\r"
    }

    /// Types `command` into the surface and submits it once the shell is
    /// running in the foreground. Unlike a fixed startup delay, polling the
    /// foreground PID means a slow-to-initialize shell doesn't swallow the
    /// command, and a fast shell doesn't wait needlessly.
    @MainActor
    static func run(_ command: String, in surface: Ghostty.SurfaceView) {
        sendWhenShellReady(command, in: surface, deadline: Date().addingTimeInterval(shellWaitTimeout))
    }

    @MainActor
    private static func sendWhenShellReady(
        _ command: String,
        in surface: Ghostty.SurfaceView,
        deadline: Date
    ) {
        if surface.surfaceModel?.foregroundPID != nil {
            send(command, in: surface)
            return
        }
        guard Date() < deadline else { return }

        // Weakly, so a tab closed while its shell is still starting can go.
        // Held strongly, the poll kept the surface — and the terminal behind
        // it — alive for the rest of the ten seconds, redispatching every
        // 50ms at a target nobody can see any more.
        DispatchQueue.main.asyncAfter(deadline: .now() + shellPollInterval) { [weak surface] in
            guard let surface else { return }
            sendWhenShellReady(command, in: surface, deadline: deadline)
        }
    }

    @MainActor
    private static func send(_ command: String, in surface: Ghostty.SurfaceView) {
        guard let model = surface.surfaceModel else { return }
        // Text injection is intentionally separate from Enter: sendText
        // treats control bytes as literal pasted text and does not emit
        // the terminal key event needed to execute the command.
        model.sendText(command)
        model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press))
        model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .release))
    }
}
