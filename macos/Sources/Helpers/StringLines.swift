import Foundation

extension String {
    /// Splits into lines at every `\n`, working in Unicode scalars.
    ///
    /// The scalars are the whole point, and the reason this exists instead
    /// of `split(separator: "\n")` at each call site.
    ///
    /// Swift counts `"\r\n"` as a **single** `Character` — one grapheme
    /// cluster, two scalars — and that `Character` is not equal to a
    /// `Character` of `"\n"`. So a `Character`-based split finds no
    /// separator anywhere in text with Windows line endings and hands back
    /// the entire input as one line. It does not throw, it does not
    /// truncate, and it does not look wrong until you check the count:
    /// three lines arrive as one. Measured: `"\r\n".count == 1`,
    /// `"\r\n".unicodeScalars.count == 2`.
    ///
    /// This has bitten three separate places in this app — streamed command
    /// output, a git failure transcript, and a unified diff — so the fix
    /// lives in one place rather than being rediscovered a fourth time.
    ///
    /// The `\r` is left on the end of each line. It is half of a terminator
    /// in most text and real content in some (a diff of a file converted to
    /// CRLF differs on every line and *only* there), so throwing it away is
    /// the caller's decision, not this one's. See
    /// ``droppingTrailingCarriageReturn``.
    func splitIntoLines() -> [String] {
        unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// The line without the `\r` that a CRLF terminator leaves behind.
    ///
    /// Only the last one, and only one of it: a bare `\r` in the middle of a
    /// line is a progress-bar overwrite and is content.
    var droppingTrailingCarriageReturn: String {
        hasSuffix("\r") ? String(dropLast()) : self
    }
}
