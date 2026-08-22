import Foundation

/// What a locked worktree's row says out loud.
///
/// A padlock on its own asks a question instead of answering one. The lock
/// is not a warning and not an error — it is a state somebody chose, and the
/// only thing a reader needs from it is *what it does to them*: git refuses
/// to prune or remove this checkout until it is unlocked. That sentence has
/// to be on screen, not behind a hover, because a tooltip is only findable
/// by someone who already suspects there is something to find.
///
/// A rule of its own because of the two shapes it comes in. `git worktree
/// lock` takes an optional `--reason`, so half the time there is a human
/// sentence to show and half the time there is nothing at all — and the
/// version with a reason must not drop the consequence, which is the part
/// the reason never states.
enum WorktreeLockNote {
    /// - Parameter reason: git's own `--reason` text, when one was given.
    ///
    /// Blank is treated as absent: `git worktree lock --reason ""` records an
    /// empty string, and rendering "Locked — git won't remove or prune it ·"
    /// with nothing after the separator looks like the sentence was cut off.
    static func text(reason: String?) -> String {
        let consequence = "Locked — git won't remove or prune it"

        guard let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return consequence }

        return "\(consequence) · \(trimmed)"
    }
}
