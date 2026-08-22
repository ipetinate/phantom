import Foundation
@testable import Ghostty
import Testing

/// How the managed-root preference's stored form becomes a path.
///
/// Only `expand` is exercised: it is the whole of the logic, and reading the
/// preference itself would mean writing to the user's own defaults from a
/// test.
struct WorktreeSettingsTests {
    private var defaultRoot: String { (NSHomeDirectory() as NSString).appendingPathComponent(".phantom/worktrees") }

    @Test func anUnsetPreferenceIsTheDefaultRoot() {
        #expect(WorktreeSettings.expand(nil) == defaultRoot)
    }

    /// A text field the user cleared writes `""`, not `nil`. Treated as a
    /// path it would be the filesystem root, and every worktree in existence
    /// would count as managed.
    @Test func anEmptyPreferenceIsTheDefaultRoot() {
        #expect(WorktreeSettings.expand("") == defaultRoot)
        #expect(WorktreeSettings.expand("   ") == defaultRoot)
    }

    /// The preference is something a person types, and `~/code/worktrees`
    /// compared against git's absolute paths matches nothing at all.
    @Test func expandsATilde() {
        #expect(WorktreeSettings.expand("~/code/worktrees")
            == (NSHomeDirectory() as NSString).appendingPathComponent("code/worktrees"))
    }

    @Test func passesAnAbsolutePathThrough() {
        #expect(WorktreeSettings.expand("/Volumes/Work/worktrees") == "/Volumes/Work/worktrees")
    }

    /// A path pasted from a terminal often arrives with a newline on it.
    @Test func trimsSurroundingWhitespace() {
        #expect(WorktreeSettings.expand("  /Volumes/Work/worktrees\n") == "/Volumes/Work/worktrees")
    }

    /// The key is part of the contract: the settings UI writes it and the
    /// pane reads it, and a rename on one side alone silently resets
    /// everybody's configured folder to the default.
    @Test func theDefaultsKeyIsStable() {
        #expect(WorktreeSettings.defaultsKey == "WorktreeManagedRoot")
    }
}
