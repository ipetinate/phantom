import Foundation

/// Where a server definition, or an external formatter, came from — and
/// therefore how far it is allowed to go without being asked about.
///
/// This travels *on the definition* rather than in a table beside it. A
/// field that rides along cannot be forgotten; a side table looked up by
/// language id can, and one missed lookup is not a bug in a UI — it is the
/// gate not running.
enum LSPServerOrigin: Hashable, Sendable {
    /// From `LSPServerRegistry.all`, compiled into this build.
    case builtIn

    /// From an `extension.json`, with the identity an approval is keyed by.
    case manifest(ExtensionProvenance)
}

/// The identity of the extension a definition came from.
///
/// Keyed by `extensionID` + `digest` and **never** by directory: a store
/// will one day want to verify these bytes with a signature instead of a
/// hash, and that has to be possible without invalidating a format people
/// have already published. Identity that is a path is identity that changes
/// when somebody reorganizes a folder.
struct ExtensionProvenance: Hashable, Sendable {
    let extensionID: String

    /// SHA-256 of the manifest's raw bytes. See `LanguageManifest.digest`.
    let digest: String

    let manifestPath: String

    let scope: LanguageManifest.Scope
}

/// What a user decided about one extension's server, as persisted.
///
/// Deliberately **not** stored in the config directory. A trust decision
/// kept next to the manifest is a trust decision the manifest's author can
/// write, and the whole point of the record is that it says something the
/// extension does not get to say about itself.
struct LanguageTrustRecord: Codable, Equatable, Sendable {
    enum Decision: String, Codable, Equatable, Sendable {
        case allowed
        case refused
    }

    /// The shape of this record.
    ///
    /// A record this build cannot decode is treated as **absent** — which
    /// means "ask", never "allowed". A future field that changes what an
    /// approval covers must therefore come with a bump, or an old build
    /// would honor an approval that was given for something else.
    var recordVersion: Int

    /// The manifest bytes this decision was made about.
    var digest: String

    /// The command as the manifest wrote it.
    var command: String

    /// Where that command resolved on `PATH` at the time.
    ///
    /// A *path*, not a hash of the binary. Pinning the contents would
    /// re-prompt after every `brew upgrade` and teach the user to click
    /// through, which is worse than not checking at all. A path that has
    /// moved is a different question: it usually means something new is
    /// earlier on `PATH`, which is exactly the case worth interrupting for.
    var resolvedPath: String

    /// Where the manifest was when the decision was made. An approval does
    /// not follow the file to a new home.
    var manifestPath: String

    var decision: Decision

    var decidedAt: Date

    var programs: [ApprovedProgram]?

    var approvedPrograms: [ApprovedProgram] {
        [ApprovedProgram(command: command, resolvedPath: resolvedPath)] + (programs ?? [])
    }
}

struct ApprovedProgram: Codable, Equatable, Sendable {
    var command: String
    var resolvedPath: String
}

/// Whether a server may be launched — the entire trust model, as one pure
/// function.
///
/// It gates **exactly one thing: `Process.run`.** Everything else an
/// extension contributes works untrusted, and that is what makes "Don't
/// Run" a usable answer instead of a broken editor: an unapproved `.ex`
/// file still highlights, still toggles comments, still completes from the
/// words in the buffer and the keywords in the manifest. Only the process
/// waits.
///
/// Pure so the tests that cover it never go near a `Process`, a
/// `UserDefaults`, or a window. Everything it needs — including the path
/// `PATH` resolution landed on — arrives as a value that somebody else
/// looked up.
enum LanguageTrust {
    /// What is being judged.
    ///
    /// Wider than `(origin, digest, record)` because three of the four
    /// invalidation rules compare something that is not in the manifest's
    /// identity: the command as written, where it resolved, and the
    /// workspace it would run in. Passing them in keeps the comparison here,
    /// where it is tested, instead of at each call site.
    struct Subject: Equatable, Sendable {
        let origin: LSPServerOrigin

        /// The digest of the manifest **as it is now**, which is the value
        /// `record.digest` is compared against.
        let digest: String

        let command: String

        /// The absolute path `LSPProcess.locate` returned. The caller
        /// resolves first: a command that cannot be found has nothing to
        /// approve, and "not installed" is not a trust answer.
        let resolvedPath: String

        /// The workspace the file being edited belongs to, when known.
        let workspaceRoot: String?
    }

    enum Verdict: Equatable, Sendable {
        /// Launch it.
        case allow

        /// Ask first, and say what changed.
        case ask(Change)

        /// Do not launch it, and do not ask.
        case deny(Denial)
    }

    /// Why a previous answer no longer covers this launch. Carried into the
    /// prompt so it can say *what* changed rather than asking again with no
    /// explanation — an unexplained repeat prompt is a prompt that gets
    /// approved out of irritation.
    enum Change: Equatable, Sendable {
        case firstRun
        case manifestChanged
        case commandChanged(previous: String)
        case commandPathChanged(previous: String)
        case manifestMoved(previous: String)
    }

    enum Denial: Equatable, Sendable {
        /// The user said no. Remembered, and reversible only from Settings:
        /// a refusal that expires when the next `.ex` file opens is a
        /// refusal the user will eventually click past.
        case refusedByUser(at: Date)

        /// The command resolved to something inside the workspace.
        ///
        /// Plenty of shells put `./node_modules/.bin` on `PATH`, so a
        /// manifest can name a perfectly innocent-looking command and rely
        /// on a freshly-cloned repository to supply it. Approving the name
        /// would then approve whatever the repo shipped.
        case commandInsideWorkspace(path: String)

        /// The command is not a program name. Already refused at parse time;
        /// checked again here because this is the last point before a
        /// process, and a defence that exists at only one layer is a
        /// defence one refactor from being gone.
        case unsafeCommand
    }

    /// Whether this launch may go ahead.
    ///
    /// The hardenings are checked before any remembered answer, because no
    /// approval makes them safe — they are not questions.
    ///
    /// A bundled manifest is then trusted by origin, which assumes the app's
    /// own `Resources` are not writable. True of a signed, installed app;
    /// **false of a local ad-hoc build**, where the bundle sits in a
    /// directory the user owns.
    ///
    /// A recorded refusal is not re-asked when the manifest changes.
    /// Otherwise touching the file would be enough to earn another prompt,
    /// and an author who can prompt repeatedly only has to wait for a
    /// distracted moment.
    static func verdict(for subject: Subject, record: LanguageTrustRecord?) -> Verdict {
        guard case .manifest(let provenance) = subject.origin else { return .allow }

        if !LanguageServerContribution.isLaunchable(subject.command) {
            return .deny(.unsafeCommand)
        }
        if let root = subject.workspaceRoot, isInside(subject.resolvedPath, root: root) {
            return .deny(.commandInsideWorkspace(path: subject.resolvedPath))
        }

        if provenance.scope == .bundled { return .allow }

        guard let record else { return .ask(.firstRun) }

        switch record.decision {
        case .refused:
            return .deny(.refusedByUser(at: record.decidedAt))

        case .allowed:
            if record.digest != subject.digest { return .ask(.manifestChanged) }
            guard let program = record.approvedPrograms.first(where: {
                $0.command == subject.command
            }) else {
                return .ask(.commandChanged(previous: record.command))
            }
            if record.manifestPath != provenance.manifestPath {
                return .ask(.manifestMoved(previous: record.manifestPath))
            }
            if program.resolvedPath != subject.resolvedPath {
                return .ask(.commandPathChanged(previous: program.resolvedPath))
            }
            return .allow
        }
    }

    /// The record to persist once the user has answered.
    static func record(
        for subject: Subject,
        decision: LanguageTrustRecord.Decision,
        at date: Date = Date(),
        extending existing: LanguageTrustRecord? = nil
    ) -> LanguageTrustRecord {
        let manifestPath: String = {
            guard case .manifest(let provenance) = subject.origin else { return "" }
            return provenance.manifestPath
        }()

        var others: [ApprovedProgram]?
        if decision == .allowed, let existing, existing.decision == .allowed,
           existing.digest == subject.digest, existing.manifestPath == manifestPath {
            let kept = existing.approvedPrograms.filter { $0.command != subject.command }
            others = kept.isEmpty ? nil : kept
        }

        return LanguageTrustRecord(
            recordVersion: LanguageTrustStore.currentRecordVersion,
            digest: subject.digest,
            command: subject.command,
            resolvedPath: subject.resolvedPath,
            manifestPath: manifestPath,
            decision: decision,
            decidedAt: date,
            programs: others
        )
    }

    /// Path containment, compared on standardized paths so `.` and `..`
    /// cannot make an inside path look outside.
    ///
    /// A workspace of `/` counts as no workspace: it is not a repository
    /// that could have shipped a binary, and treating it as one would deny
    /// every server for any file opened outside a project.
    static func isInside(_ path: String, root: String) -> Bool {
        let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardizedRoot != "/", !standardizedRoot.isEmpty else { return false }
        let prefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        return standardizedPath.hasPrefix(prefix)
    }
}
