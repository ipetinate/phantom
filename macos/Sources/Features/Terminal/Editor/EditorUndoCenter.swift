import CryptoKit
import Foundation

/// Every file's undo history, for as long as the app is running.
///
/// ## Why it is not on the document
///
/// `EditorDocument` already outlives the view — which is what makes it the
/// obvious home — but it does not outlive the *tab*: `EditorCenter.close`
/// removes it from `documents` and the last reference goes with it. The reader
/// asked for undo that survives closing a file and coming back to it, so the
/// history has to be held by something that survives a document, and this is
/// the only thing in the editor that does.
///
/// ## What it does not promise
///
/// Nothing here is written to disk. Quit the app and every timeline goes with
/// it: reopening a file in a new launch starts with an empty history. That is
/// a deliberate line rather than an oversight — persisting undo means writing
/// the contents of files the reader never saved into a cache directory, and
/// deciding when to expire it, which is a larger promise than the one being
/// made here.
///
/// ## The rule that makes it safe
///
/// A timeline describes edits to *a particular text*. While a file is open the
/// two cannot drift, because every step is recorded from the buffer as it
/// changes. While it is closed they can: a `git checkout` in the terminal
/// sitting next to the editor rewrites the file, and the steps still in memory
/// then describe a document that no longer exists. Undoing into that would
/// splice old text into a file somebody else changed and, on the next ⌘S,
/// write the result over their work — the one outcome an editor may never
/// produce quietly.
///
/// So the text is fingerprinted at ``detach(path:text:)`` and checked again at
/// ``attach(path:text:)``. A file that comes back different comes back with no
/// history. The reader loses an undo stack they had probably forgotten about;
/// the alternative loses somebody's commit.
@MainActor
final class EditorUndoCenter {
    static let shared = EditorUndoCenter()

    /// How many files keep a history at once.
    ///
    /// Thirty-two, which is more than the tab bar holds — so every file
    /// actually open keeps its history, and only ones abandoned long ago are
    /// dropped. Combined with ``CodeUndoTimeline/maximumBytes`` it puts a
    /// ceiling of 64 MiB on the whole feature, reachable only by filling
    /// thirty-two separate files with megabytes of edits; a day of ordinary
    /// work leaves it in the tens of kilobytes.
    static let maximumFiles = 32

    private struct Entry {
        let timeline: CodeUndoTimeline

        /// The text this timeline was last known to describe, or nil while the
        /// file is open and the two cannot drift.
        var fingerprint: Data?

        /// When it was last asked for, for the eviction order.
        var touched: Date
    }

    private var entries: [String: Entry] = [:]

    /// The history for a file that is being opened, empty when the file has
    /// changed since it was last put down.
    ///
    /// Idempotent: opening a file that is already open hands back the same
    /// timeline untouched, because an open file has no fingerprint to fail.
    @discardableResult
    func attach(path: String, text: String) -> CodeUndoTimeline {
        guard var entry = entries[path] else {
            let timeline = CodeUndoTimeline()
            entries[path] = Entry(timeline: timeline, fingerprint: nil, touched: Date())
            evictIfNeeded()
            return timeline
        }

        if let fingerprint = entry.fingerprint, fingerprint != Self.fingerprint(of: text) {
            entry.timeline.clear()
        }
        entry.fingerprint = nil
        entry.touched = Date()
        entries[path] = entry
        return entry.timeline
    }

    /// The history for a file, made if this is the first anyone has asked.
    ///
    /// For the view, which needs the timeline on every rebuild and has no
    /// business deciding whether that rebuild is an open. The disk check
    /// belongs to ``attach(path:text:)`` and happens once, where the text
    /// being opened is actually known.
    func timeline(forPath path: String) -> CodeUndoTimeline {
        if var entry = entries[path] {
            entry.touched = Date()
            entries[path] = entry
            return entry.timeline
        }

        let timeline = CodeUndoTimeline()
        entries[path] = Entry(timeline: timeline, fingerprint: nil, touched: Date())
        evictIfNeeded()
        return timeline
    }

    /// Notes what the file held as it was closed, so the history can be
    /// checked against the file if it is ever opened again.
    ///
    /// The gesture in progress is registered first. A run of typing that was
    /// still growing when the tab closed is a step the reader expects to get
    /// back, and it only exists inside the timeline until something ends it.
    func detach(path: String, text: String) {
        guard var entry = entries[path] else { return }
        entry.timeline.flush()
        entry.timeline.target = nil
        entry.fingerprint = Self.fingerprint(of: text)
        entry.touched = Date()
        entries[path] = entry
    }

    /// Throws a file's history away.
    ///
    /// For the two moments where every step in it has been invalidated at
    /// once: the file was reloaded from disk under the reader, or it was
    /// deleted. The timeline object is kept rather than removed so a view
    /// still holding it keeps recording into the thing the store will hand
    /// out next.
    func invalidate(path: String) {
        entries[path]?.timeline.clear()
    }

    /// Follows a file that was renamed or moved, so the history moves with the
    /// buffer instead of being left at an address nothing will ask for again.
    func repath(from oldPath: String, to newPath: String) {
        guard oldPath != newPath, var entry = entries.removeValue(forKey: oldPath) else { return }
        entry.touched = Date()
        entries[newPath] = entry
    }

    /// Whether a path has anything to take back, for tests and for anything
    /// that has to answer the question without a text view.
    func hasHistory(forPath path: String) -> Bool {
        entries[path]?.timeline.canUndo ?? false
    }

    func forgetEverything() {
        entries.removeAll()
    }

    /// Drops the least recently used files until the map is within its bound.
    ///
    /// Open files are never candidates: an entry with no fingerprint is one
    /// whose view may be recording into it right now, and evicting that would
    /// leave a live buffer writing steps into a timeline nothing will ever
    /// hand back.
    private func evictIfNeeded() {
        guard entries.count > Self.maximumFiles else { return }

        let closed = entries
            .filter { $0.value.fingerprint != nil }
            .sorted { $0.value.touched < $1.value.touched }

        var over = entries.count - Self.maximumFiles
        for (path, _) in closed where over > 0 {
            entries.removeValue(forKey: path)
            over -= 1
        }
    }

    /// A digest rather than the text itself.
    ///
    /// Keeping the text would answer the same question exactly and would mean
    /// holding a second copy of every file that has been closed, which is the
    /// memory this class is otherwise careful about. Thirty-two bytes of
    /// SHA-256 costs one pass over the file at close and one at open.
    private static func fingerprint(of text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }
}
