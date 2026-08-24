import AppKit

/// One change to a buffer, in enough detail to be taken back and put again.
///
/// Both halves of the replacement are kept, which an `NSTextView` undo record
/// does not need and this does: the timeline outlives the view that made the
/// edit, so at the moment a step is undone there may be nothing left that
/// remembers what used to be there.
///
/// The selection travels with it for the same reason a caret travels through
/// a format. Undo that restores the text and leaves the caret at the end of
/// the file is only half of "take that back" — the reader was somewhere, and
/// the point of undoing is to be there again.
struct CodeUndoStep: Equatable {
    /// Where the edit landed, in UTF-16 offsets into the text **before** it.
    var range: NSRange

    /// What used to be in `range`. Empty for a pure insertion.
    var removed: String

    /// What is in `range` now. Empty for a pure deletion.
    var inserted: String

    var selectionBefore: NSRange
    var selectionAfter: NSRange

    /// What the Edit menu calls this step — "Typing", "Formatting".
    var name: String

    /// The span `inserted` occupies once the edit has been applied, which is
    /// what has to be replaced to take it back.
    var rangeAfter: NSRange {
        NSRange(location: range.location, length: (inserted as NSString).length)
    }

    /// What holding this step costs, measured the way `String` stores it.
    var byteCount: Int { removed.utf8.count + inserted.utf8.count }
}

extension CodeUndoStep {
    /// The two steps as one, when `next` continues the same gesture — or nil
    /// when it starts a new one.
    ///
    /// Coalescing is not a nicety. Without it every keystroke is its own ⌘Z,
    /// and taking back a sentence means holding the shortcut down and watching
    /// it come apart one character at a time. `NSTextView` does this for its
    /// own stack and this timeline cannot borrow that, because the whole point
    /// of the timeline is to survive the view.
    ///
    /// A gesture continues while the reader is doing the same thing in the
    /// same place:
    ///
    /// - **Typing**: both steps insert, the second begins exactly where the
    ///   first ended, and the caret went straight from one to the other. The
    ///   caret test is what breaks the run when somebody clicks elsewhere and
    ///   types again — two insertions at unrelated offsets are two gestures
    ///   even if no time passed.
    /// - **Backspace**: both steps delete, and the second ends where the
    ///   first began.
    /// - **Forward delete**: both steps delete at the same offset, which is
    ///   what repeatedly deleting forward looks like.
    ///
    /// A newline ends a typing run either way, so undo gives back a line at a
    /// time rather than the whole paragraph. Time is the caller's to judge —
    /// see ``CodeUndoTimeline/coalescingWindow`` — because a pause is a
    /// boundary too and this type has no clock.
    func continuing(_ next: CodeUndoStep) -> CodeUndoStep? {
        if isInsertion, next.isInsertion {
            guard !inserted.contains("\n"), !next.inserted.contains("\n") else { return nil }
            guard next.range.location == rangeAfter.location + rangeAfter.length else { return nil }
            guard next.selectionBefore.length == 0,
                  next.selectionBefore.location == selectionAfter.location else { return nil }

            var merged = self
            merged.inserted += next.inserted
            merged.selectionAfter = next.selectionAfter
            return merged
        }

        guard isDeletion, next.isDeletion else { return nil }

        /// Backspace: the newer deletion sits immediately before the older
        /// one, so the combined range starts where the newer one did and the
        /// removed text reads newer-then-older.
        if next.range.location + next.range.length == range.location {
            var merged = self
            merged.range = NSRange(
                location: next.range.location,
                length: next.range.length + range.length)
            merged.removed = next.removed + removed
            merged.selectionAfter = next.selectionAfter
            return merged
        }

        /// Forward delete: both bite at the same offset, so the ranges add up
        /// and the removed text reads in the order it was taken.
        if next.range.location == range.location {
            var merged = self
            merged.range = NSRange(
                location: range.location,
                length: range.length + next.range.length)
            merged.removed = removed + next.removed
            merged.selectionAfter = next.selectionAfter
            return merged
        }

        return nil
    }

    private var isInsertion: Bool { removed.isEmpty && !inserted.isEmpty }
    private var isDeletion: Bool { inserted.isEmpty && !removed.isEmpty }
}

/// What a timeline needs of the thing showing the file: somewhere to put the
/// text back.
///
/// A protocol rather than a reference to the text view so the timeline can be
/// driven — and its bounds, its ordering and its refusals asserted — without a
/// window, a layout manager or a run loop anywhere near it.
@MainActor
protocol CodeUndoTarget: AnyObject {
    /// Puts `step` back (`undoing`) or puts it again (`!undoing`), moving the
    /// selection to match and showing the reader where it landed.
    func applyUndoStep(_ step: CodeUndoStep, undoing: Bool)
}

/// One file's undo history, kept somewhere the view cannot take it with it.
///
/// ## Why this exists at all
///
/// `CodeNSTextView` owned an `UndoManager` as a stored property. The pane that
/// shows a document is tagged `.id(document.id)`, so SwiftUI destroys and
/// rebuilds it whenever the selected tab changes — and an undo stack stored on
/// a view is deallocated with the view. That is the whole of "⌘Z stops working
/// when I switch tabs": nothing was cleared and nothing failed, the stack
/// simply was not there any more. Anchoring the stack to the *file* instead of
/// to the view it happens to be drawn in is the fix, and it is also what lets
/// a tab be closed and reopened with its history intact, since the store that
/// holds these outlives any document.
///
/// ## Why it is still an `UndoManager` underneath
///
/// Because ⌘Z arrives through the responder chain and the Edit menu, and
/// `UndoManager` is what that machinery is built to ask. Reimplementing the
/// stack would mean reimplementing redo, nested grouping — which
/// `applyCompletion` depends on to make one ⌘Z take back a completion and the
/// import it dragged in — and the action names the menu puts in its title.
/// What is *not* borrowed is `NSTextView`'s own registration: `allowsUndo` is
/// off, and every step here is registered against **this object**, never
/// against the view. An action registered against a view that no longer exists
/// has nothing to put the text back into, which is the failure this class was
/// written to remove rather than to move.
///
/// ## Grouping is explicit, and this manager is not the view's
///
/// `groupsByEvent` is off. Left on, `UndoManager` opens a group per pass of
/// the run loop and closes it at the end, so everything registered in one pass
/// becomes one ⌘Z — and the pass in which a formatter splices its edit is also
/// the pass in which the typing run before it is registered, so ⌘Z after ⇧⌘F
/// would take back the formatting *and* the last thing the reader typed.
///
/// That is why `CodeNSTextView` keeps a second, ordinary `UndoManager` and
/// hands *that* one to AppKit. `NSTextView` reaches into the manager it is
/// given during `shouldChangeTextInRange:` — `coalesceInTextView:` asks it to
/// prepare an event group — and throws when it finds `groupsByEvent` off. So
/// AppKit gets a manager shaped the way AppKit needs, nothing real is
/// registered on it because `allowsUndo` is false, and the file's history is
/// grouped by gesture rather than by run loop.
@MainActor
final class CodeUndoTimeline {
    /// How many steps are kept.
    ///
    /// Two hundred coalesced gestures — not keystrokes — which is far past
    /// the depth anybody walks back by hand and still a hard ceiling rather
    /// than a hope.
    static let maximumSteps = 200

    /// How much text the whole timeline may hold, summed over the steps'
    /// removed and inserted halves.
    ///
    /// Two mebibytes, against a typical step of a few dozen bytes: roughly
    /// four thousand ordinary gestures, and about eight times the per-buffer
    /// budget Emacs has defaulted to for decades. An unbounded per-file
    /// history is a leak with a friendly name, and this is the number that
    /// makes the leak impossible to reach by typing.
    static let maximumBytes = 2 * 1024 * 1024

    /// The largest single step worth keeping.
    ///
    /// Half a mebibyte. Above that the change is reload-scale — a branch
    /// switch, a paste of a generated file — and holding both halves of it
    /// for every file that has ever been open costs more than the undo is
    /// worth. Such a step is refused and the timeline is emptied rather than
    /// left holding steps that describe text either side of a gap.
    static let maximumStepBytes = 512 * 1024

    /// How long a typing run may pause before the next keystroke starts a
    /// new step.
    ///
    /// One second: longer than any gap inside a burst of typing, short enough
    /// that stopping to think reads as a boundary — which is what makes ⌘Z
    /// give back a phrase rather than a paragraph.
    static let coalescingWindow: TimeInterval = 1

    /// The view currently showing this file, or nil while no tab has it open.
    ///
    /// Weak, and deliberately so: the timeline outliving the view is the
    /// entire point, and a strong reference here would keep a destroyed pane's
    /// text view — and its layout manager, and its storage — alive for as long
    /// as the app remembered the file.
    weak var target: (any CodeUndoTarget)?

    /// The stack the Edit menu asks.
    let manager: UndoManager

    /// Set while a step is being put back, so the edit that results is not
    /// recorded as a new one. Without it, undoing would append the inverse of
    /// what it just undid and the next ⌘Z would put it straight back.
    private(set) var isApplying = false

    /// The gesture in progress, not yet registered.
    ///
    /// Registration is deferred to the end of a gesture because `UndoManager`
    /// cannot replace the action on top of its stack, and coalescing needs
    /// exactly that — a run of typing is one step that keeps growing. Holding
    /// it here until something ends it is what lets it grow at all.
    private var pending: (step: CodeUndoStep, time: TimeInterval)?

    /// What each registered step costs, oldest first, mirroring the stack so
    /// the byte budget can be applied without asking `UndoManager` a question
    /// it does not answer.
    private var registeredBytes: [Int] = []

    private(set) var byteCount = 0

    init() {
        manager = UndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = Self.maximumSteps
    }

    // MARK: What the menu asks

    var canUndo: Bool { pending != nil || manager.canUndo }
    var canRedo: Bool { manager.canRedo }

    var undoActionName: String { pending?.step.name ?? manager.undoActionName }
    var redoActionName: String { manager.redoActionName }

    /// Takes back the newest step, answering whether there was one.
    @discardableResult
    func undo() -> Bool {
        flush()
        guard manager.canUndo, target != nil else { return false }
        manager.undo()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard manager.canRedo, target != nil else { return false }
        manager.redo()
        return true
    }

    /// Makes everything recorded until ``endGrouping()`` one ⌘Z.
    ///
    /// For a writer that makes several edits which have to travel together —
    /// a completion and the import it dragged in. The gesture in progress is
    /// ended first, so what the reader typed before does not get swept into
    /// the group.
    func beginGrouping() {
        flush()
        manager.beginUndoGrouping()
    }

    func endGrouping() {
        flush()
        manager.endUndoGrouping()
    }

    // MARK: Recording

    /// Notes an edit that has just happened to the buffer.
    ///
    /// `time` is passed in rather than read from a clock so the coalescing
    /// window can be stated by a test instead of waited out by one.
    func record(_ step: CodeUndoStep, at time: TimeInterval) {
        guard !isApplying else { return }
        guard !step.removed.isEmpty || !step.inserted.isEmpty else { return }

        if let pending,
           time - pending.time < Self.coalescingWindow,
           let merged = pending.step.continuing(step) {
            self.pending = (merged, time)
            return
        }

        flush()
        pending = (step, time)
    }

    /// Registers the gesture in progress, ending it.
    ///
    /// Called before anything that has to see a settled stack — an undo, a
    /// redo, a replacement made by the host, the file being closed — and by
    /// `record` itself when the next edit starts a new gesture.
    func flush() {
        guard let pending else { return }
        self.pending = nil
        register(pending.step)
    }

    /// Forgets everything.
    ///
    /// The safety valve as much as the housekeeping call: a timeline whose
    /// steps describe text the buffer no longer holds is worse than no
    /// timeline, because undoing through it writes something nobody typed.
    func clear() {
        pending = nil
        manager.removeAllActions()
        registeredBytes.removeAll()
        byteCount = 0
        manager.levelsOfUndo = Self.maximumSteps
    }

    // MARK: Applying

    /// Puts a step back, or puts it again, and leaves the opposite move on the
    /// stack.
    ///
    /// The re-registration is what gives redo for nothing: `UndoManager` sends
    /// anything registered while it is undoing to the redo stack, so the same
    /// method serves both directions and the two can never disagree about what
    /// a step was.
    private func apply(_ step: CodeUndoStep, undoing: Bool) {
        guard let target else { return }

        isApplying = true
        target.applyUndoStep(step, undoing: undoing)
        isApplying = false

        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { timeline in
            timeline.apply(step, undoing: !undoing)
        }
        manager.setActionName(step.name)
        manager.endUndoGrouping()
    }

    private func register(_ step: CodeUndoStep) {
        guard step.byteCount <= Self.maximumStepBytes else {
            clear()
            return
        }

        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { timeline in
            timeline.apply(step, undoing: true)
        }
        manager.setActionName(step.name)
        manager.endUndoGrouping()

        registeredBytes.append(step.byteCount)
        byteCount += step.byteCount
        trimToBudget()
    }

    /// Drops the oldest steps until the timeline fits both bounds.
    ///
    /// `UndoManager` offers no "drop the oldest" call, but lowering
    /// `levelsOfUndo` does exactly that and keeps the ceiling wherever it is
    /// next set — so the budget is applied by lowering the limit to the number
    /// of steps that fit and raising it straight back. Zero is skipped
    /// because `levelsOfUndo = 0` means *unlimited*, which is the one value
    /// that would turn this method into the bug it prevents.
    private func trimToBudget() {
        while registeredBytes.count > 1, byteCount > Self.maximumBytes {
            byteCount -= registeredBytes.removeFirst()
        }
        while registeredBytes.count > Self.maximumSteps {
            byteCount -= registeredBytes.removeFirst()
        }

        guard registeredBytes.count > 0 else { return }
        manager.levelsOfUndo = registeredBytes.count
        manager.levelsOfUndo = Self.maximumSteps
    }
}
