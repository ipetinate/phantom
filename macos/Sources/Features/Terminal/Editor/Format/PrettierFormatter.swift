import Foundation

/// The three halves put together: find the project, find the Prettier, run it,
/// and hand back the smallest edit that applies the result.
///
/// This is the only file in `Format/` that knows about the rest of the app —
/// the login shell's `PATH` and the executable lookup the language servers
/// already use. Everything it calls into is pure or process-local, which is
/// what lets the discovery, the decision, the empty-output rule and the edit
/// be tested without a Prettier on the machine.
enum PrettierFormatter {
    /// Which Prettier to run for a project.
    ///
    /// The project's own comes first, and by a wide margin: a repository pins
    /// a Prettier version in its lockfile precisely so that everyone's saves
    /// produce the same diff, and reformatting with whatever major version
    /// happens to be on this machine's `PATH` would put a stranger's line
    /// breaks into every file the reader touches.
    ///
    /// The `PATH` fallback is the login shell's, not the app's:
    /// a GUI process launched from the Dock inherits `launchd`'s
    /// `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, where no version manager has ever
    /// installed anything. `LoginEnvironment` is the existing answer to that
    /// and the language servers already resolve through it.
    ///
    /// Blocks on first use — resolving that `PATH` costs a login shell. Never
    /// call it on the main actor.
    static func binary(for project: PrettierProject) -> String? {
        if let local = project.localBinaryPath { return local }
        return LSPProcess.locate("prettier", searchPath: LoginEnvironment.executableSearchPath())
    }

    /// What Prettier said, or nil when it declined to say anything — the file
    /// is covered by an ignore rule.
    ///
    /// Deliberately *not* also nil for "already formatted". Deciding that is
    /// `PrettierEdit`'s job, and it decides on code units, where `==` on
    /// `String` decides on canonical equivalence — so a normalisation-only
    /// difference would be dropped here and then produced as an edit there,
    /// and the two layers would disagree about whether the buffer changed.
    ///
    /// Blocking; background tasks only.
    ///
    /// - Throws: `PrettierFailure`.
    static func format(
        _ text: String,
        at path: String,
        in project: PrettierProject,
        timeout: TimeInterval = PrettierRunner.defaultTimeout
    ) throws -> String? {
        guard let binary = binary(for: project) else { throw PrettierFailure.notFound }

        return try PrettierRunner.format(
            text,
            filePath: path,
            binary: binary,
            workingDirectory: project.workingDirectory,
            environment: LoginEnvironment.executableEnvironment(),
            timeout: timeout
        )
    }

    /// What a caller actually wants: the edit to apply, or nothing to do.
    ///
    /// Both ways of having nothing to do collapse into the same `nil` on
    /// purpose. "Prettier declined to touch this file" and "Prettier's answer
    /// is the text you already have" are the same instruction to the buffer,
    /// and a caller that had to tell them apart would eventually get one of
    /// them wrong in the direction that overwrites the file. This is the entry
    /// point a save path should use for exactly that reason.
    ///
    /// Blocking; background tasks only.
    ///
    /// - Throws: `PrettierFailure`.
    static func edit(
        for text: String,
        at path: String,
        in project: PrettierProject,
        timeout: TimeInterval = PrettierRunner.defaultTimeout
    ) throws -> PrettierEdit? {
        guard let formatted = try format(text, at: path, in: project, timeout: timeout) else { return nil }
        return PrettierEdit.minimal(from: text, to: formatted)
    }

    /// Discovery, decision and run in one call, for a caller holding nothing
    /// but a path and a buffer.
    ///
    /// Returns nil — rather than throwing `notFound` — when Prettier does not
    /// own the file. Being asked to format a `.rs` file in a Rust repository
    /// is not an error, it is a "no", and a save path that raised a banner
    /// for it would be unusable.
    ///
    /// Blocking; background tasks only.
    ///
    /// - Throws: `PrettierFailure`.
    static func edit(
        for text: String,
        at path: String,
        timeout: TimeInterval = PrettierRunner.defaultTimeout
    ) throws -> PrettierEdit? {
        let project = PrettierProject.discover(forFile: path)
        guard project.handles(fileNamed: (path as NSString).lastPathComponent) else { return nil }
        return try edit(for: text, at: path, in: project, timeout: timeout)
    }
}
