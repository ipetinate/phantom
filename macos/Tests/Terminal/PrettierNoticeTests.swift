import Foundation
@testable import Ghostty
import Testing

/// Which of Prettier's outcomes are allowed to interrupt the reader.
///
/// The rule is one sentence — an alert is for a failure somebody is waiting on
/// — and every case here is a way of getting it wrong: announcing a file that
/// was already tidy, confirming a reformat the reader can see, or raising the
/// missing-Prettier dialog on a keystroke that only asked for the file to be
/// written.
struct PrettierNoticeTests {
    // MARK: Nothing happened

    /// The complaint this exists for. ⇧⌘F on an already-formatted file is the
    /// outcome the keystroke was pressed to reach, and it used to put a dialog
    /// in front of it.
    @Test func nothingToChangeIsSilentOnTheExplicitCommand() {
        let notice = FormatAttempt.answered(nil).notice(for: .command)

        #expect(notice == nil, "\(String(describing: notice))")
    }

    /// The same outcome on the path that never spoke anyway, pinned so the two
    /// cannot drift into disagreeing about it.
    @Test func nothingToChangeIsSilentOnSave() {
        let notice = FormatAttempt.answered(nil).notice(for: .save)

        #expect(notice == nil, "\(String(describing: notice))")
    }

    /// Prettier does not own this file, so nothing has been decided yet: the
    /// language server still gets its turn below, and reports for itself.
    @Test func aFileTheProjectDoesNotCoverIsSilent() {
        let notice = FormatAttempt.notOurs.notice(for: .command)

        #expect(notice == nil, "\(String(describing: notice))")
    }

    // MARK: It worked

    /// The text moving in front of the reader is the receipt. A modal on top
    /// of it is a second one.
    @Test func aReformatIsSilentOnEitherTrigger() {
        let edit = PrettierEdit(range: NSRange(location: 0, length: 1), newText: "  ")

        for trigger in [EditorFormatTrigger.command, .save] {
            let notice = FormatAttempt.answered(edit).notice(for: trigger)

            #expect(notice == nil, "\(trigger): \(String(describing: notice))")
        }
    }

    // MARK: It failed

    /// The one outcome that survives. The reader asked for something, did not
    /// get it, and the reason is the only place the parse error's line and
    /// column exist — so it has to reach the alert whole.
    @Test func aFailureOnTheExplicitCommandCarriesTheReason() {
        let reason = PrettierFailure
            .failed(status: 2, message: "[error] main.ts: Unexpected token (3:7)")
            .reason
        let notice = FormatAttempt.failed(reason).notice(for: .command)

        #expect(notice?.contains(reason) == true, "\(String(describing: notice))")
    }

    /// A ⌘S asked for the file to be on disk, not to be formatted. In a
    /// project with no Prettier installed the alternative is this dialog on
    /// every single write, which is how alerts stop being read — and the write
    /// goes through either way.
    @Test func aFailureOnSaveIsSilent() {
        let notice = FormatAttempt.failed(PrettierFailure.notFound.reason).notice(for: .save)

        #expect(notice == nil, "\(String(describing: notice))")
    }
}
