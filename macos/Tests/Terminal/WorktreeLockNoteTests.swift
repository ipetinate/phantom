import Foundation
@testable import Ghostty
import Testing

/// What a locked worktree's row says.
///
/// Small, and worth pinning anyway: the property that matters is that the
/// consequence never drops out. A padlock with a reason beside it explains
/// why somebody locked the worktree and says nothing about what the lock
/// does — which is the only part the reader is actually blocked by.
struct WorktreeLockNoteTests {
    @Test func aLockWithNoReasonStillSaysWhatItDoes() {
        #expect(WorktreeLockNote.text(reason: nil)
            == "Locked — git won't remove or prune it")
    }

    /// The reason rides along; it does not replace the consequence. "On the
    /// external drive" answers *why somebody did this* and leaves *what it
    /// means for me* unanswered.
    @Test func aReasonIsAddedToTheConsequenceRatherThanReplacingIt() {
        let note = WorktreeLockNote.text(reason: "on the external drive")

        #expect(note.hasPrefix("Locked — git won't remove or prune it"))
        #expect(note.hasSuffix("on the external drive"))
    }

    /// `git worktree lock --reason ""` records an empty string, and a
    /// separator with nothing after it reads as a sentence that got cut off.
    @Test func aBlankReasonIsTreatedAsNoReason() {
        let plain = WorktreeLockNote.text(reason: nil)

        #expect(WorktreeLockNote.text(reason: "") == plain)
        #expect(WorktreeLockNote.text(reason: "   ") == plain)
        #expect(WorktreeLockNote.text(reason: "\n") == plain)
    }

    /// Git keeps whatever whitespace the reason was written with, including
    /// the newline a shell heredoc leaves on the end.
    @Test func aReasonIsTrimmedOfWhatGitKept() {
        #expect(WorktreeLockNote.text(reason: "  on the external drive\n")
            == WorktreeLockNote.text(reason: "on the external drive"))
    }

    /// Nothing is truncated here. How much fits is the row's problem, and it
    /// has a width to decide it with — this rule does not.
    @Test func aLongReasonIsLeftWhole() {
        let long = String(repeating: "a network mount that comes and goes ", count: 4)

        #expect(WorktreeLockNote.text(reason: long).hasSuffix(
            long.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
