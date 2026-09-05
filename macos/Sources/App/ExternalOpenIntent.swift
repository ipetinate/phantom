import Foundation

/// What to do with a path handed to the app from outside — the Finder, a
/// drop on the Dock icon, `open -a`.
///
/// Upstream Ghostty has one answer for a file, and it is the right one for a
/// terminal emulator: **run it**, the way Terminal and iTerm2 do. Phantom is
/// also an editor, and there the same gesture means the opposite. Opening
/// `config.ts` from the Finder ran the file as a shell script — the contents
/// of a source file executed against a login shell, which is a hazard rather
/// than a surprise.
///
/// A value with its own tests, because this is the decision that was wrong
/// and it should be possible to be sure about it without a Finder, a window
/// or a shell.
enum ExternalOpenIntent: Equatable {
    /// Open a terminal there.
    case workingDirectory

    /// Run it, with the confirmation upstream already requires.
    case execute

    /// Show it in the editor.
    case edit

    /// - Parameter isExecutable: the file's executable bit, not its
    ///   extension. A `.sh` without the bit is something someone is reading;
    ///   a file with the bit is something someone means to run, whatever it
    ///   is called. It is also the same bit the shell itself would consult,
    ///   so the rule agrees with what running it would actually do.
    static func decide(isDirectory: Bool, isExecutable: Bool) -> ExternalOpenIntent {
        if isDirectory { return .workingDirectory }
        return isExecutable ? .execute : .edit
    }

    /// Reads the bit from disk.
    ///
    /// Separate from `decide` so the rule stays testable without a
    /// filesystem, and so the one place that touches disk is obvious.
    static func decide(forPath path: String, fileManager: FileManager = .default) -> ExternalOpenIntent? {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }

        return decide(
            isDirectory: isDirectory.boolValue,
            isExecutable: fileManager.isExecutableFile(atPath: path)
        )
    }
}
