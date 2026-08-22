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

    // MARK: The reason on its own

    /// The row and the info popover both ask this, and they must not
    /// disagree about what counts as "there is a reason".
    @Test func theReasonIsSharedBetweenTheRowAndThePopover() {
        #expect(WorktreeLockNote.reason("on the external drive") == "on the external drive")
        #expect(WorktreeLockNote.reason(nil) == nil)
        #expect(WorktreeLockNote.reason("") == nil)
        #expect(WorktreeLockNote.reason("  \n ") == nil)
        #expect(WorktreeLockNote.reason("  spaced  ") == "spaced")
    }

    /// Whenever the row shows a reason, the popover has one to show too.
    @Test func theRowNeverNamesAReasonThePopoverWouldHide() {
        for raw in [nil, "", "   ", "on the external drive", " trimmed \n"] {
            let inRow = WorktreeLockNote.text(reason: raw).contains(" · ")
            #expect(inRow == (WorktreeLockNote.reason(raw) != nil), "\(raw ?? "nil")")
        }
    }

    /// Nothing is truncated here. How much fits is the row's problem, and it
    /// has a width to decide it with — this rule does not.
    @Test func aLongReasonIsLeftWhole() {
        let long = String(repeating: "a network mount that comes and goes ", count: 4)

        #expect(WorktreeLockNote.text(reason: long).hasSuffix(
            long.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
