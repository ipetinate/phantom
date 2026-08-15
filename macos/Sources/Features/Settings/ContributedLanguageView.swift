import SwiftUI

/// What a contributed language's row has to say about itself.
///
/// Assembled here rather than read off the model, because there is no one
/// field that answers it: whether a contribution is in force lives in
/// `LanguageCatalog.Resolution`, whether it may contribute a *server* lives
/// in `LanguageManifest.ServerEligibility`, and whether that server may be
/// launched lives in `LanguageTrust.Verdict`. Three answers from three
/// layers, and a row can only show one — so the order below is the whole
/// content of this type, and it runs most-inert first. A shadowed
/// contribution is not doing anything at all, so saying it is "not
/// approved" would be true and useless.
///
/// The three-layer split is deliberate upstream and worth not flattening:
/// eligibility is decided at parse time and cannot be argued with, trust is
/// a decision the user makes and can revisit, and resolution is about which
/// of several files wins. Collapsing them into one status field on the
/// model would make every future case pick a layer to lie about.
enum ContributedStatus: Equatable {
    /// In force, approved, ready to launch.
    case ready

    /// In force with no server of its own — highlighting, comments and
    /// keywords, and nothing to approve. A perfectly good state, and by far
    /// the most common one for a language pack.
    case noServer

    /// Never approved. The language works; only the process waits.
    case untrusted

    /// Approved once, but something the approval named has changed.
    case needsReapproval(String)

    /// The user said no, and it stuck.
    case refused

    /// The manifest declares a schema this build cannot read, so its server
    /// half was discarded — see `LanguageManifest.ServerEligibility`.
    case needsNewerApp(declared: String)

    /// No usable `id`, so no approval could be recorded for it.
    case unidentified

    /// The command is not a program name, or resolves inside the workspace.
    /// Refused outright rather than asked about.
    case blocked(String)

    /// Parsed and listed, but something ahead of it already claims a file
    /// type it wanted.
    case shadowed(by: String, claim: String)

    @MainActor
    static func of(_ contributed: LanguageCatalog.Contributed) -> ContributedStatus {
        if case .shadowed(let shadow, let claim) = contributed.resolution {
            let owner: String
            switch shadow {
            case .builtIn: owner = "Phantom"
            case .extensionID(let id): owner = id
            }
            return .shadowed(by: owner, claim: claim)
        }

        switch contributed.language.serverRejection {
        case .ineligible(.needsNewerApp(let declared)):
            return .needsNewerApp(declared: declared)
        case .ineligible(.unidentified):
            return .unidentified
        case .unsafeCommand(let command):
            return .blocked(command)
        case .ineligible(.eligible), .missingCommand, .none:
            break
        }

        guard let server = contributed.language.server else { return .noServer }

        /// The command itself as the resolved path, per `trustVerdict`'s own
        /// note: this row is asking "would this be approved", not launching
        /// anything, and looking the binary up on `PATH` from a settings
        /// screen would block the main actor to answer a question the row
        /// does not need answered.
        guard let verdict = LanguageResolver.shared.trustVerdict(
            for: contributed,
            resolvedPath: server.command
        ) else {
            return .noServer
        }

        switch verdict {
        case .allow:
            return .ready
        case .ask(.firstRun):
            return .untrusted
        case .ask(.manifestChanged):
            return .needsReapproval("the manifest changed since you approved it")
        case .ask(.commandChanged(let previous)):
            return .needsReapproval("it used to run \(previous)")
        case .ask(.commandPathChanged(let previous)):
            return .needsReapproval("the command used to resolve to \(previous)")
        case .ask(.manifestMoved(let previous)):
            return .needsReapproval("the manifest moved from \(previous)")
        case .deny(.refusedByUser):
            return .refused
        case .deny(.commandInsideWorkspace(let path)):
            return .blocked(path)
        case .deny(.unsafeCommand):
            return .blocked(server.command)
        }
    }

    var title: String {
        switch self {
        case .ready: return "Approved"
        case .noServer: return "No Server"
        case .untrusted: return "Not Approved"
        case .needsReapproval: return "Approval Out of Date"
        case .refused: return "Refused"
        case .needsNewerApp: return "Needs a Newer Phantom"
        case .unidentified: return "Missing Extension ID"
        case .blocked: return "Blocked"
        case .shadowed: return "Shadowed"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.seal"
        case .noServer: return "text.aligncenter"
        case .untrusted, .needsReapproval: return "questionmark.circle"
        case .refused, .blocked: return "hand.raised"
        case .needsNewerApp: return "arrow.up.circle"
        case .unidentified: return "exclamationmark.triangle"
        case .shadowed: return "square.stack.3d.down.forward"
        }
    }

    /// Red only for a decision that stops something, orange for one waiting
    /// on the reader, grey for a state that is simply how things are — a
    /// language pack with no server is not a problem and should not be
    /// coloured like one.
    var color: Color {
        switch self {
        case .ready: return .green
        case .noServer, .shadowed: return .secondary
        case .untrusted, .needsReapproval, .needsNewerApp: return .orange
        case .refused, .blocked, .unidentified: return .red
        }
    }

    /// The sentence under the badge. Says what is true *and* what still
    /// works, because the whole point of gating only `Process.run` is that
    /// an unapproved language is not a broken one.
    var explanation: String {
        switch self {
        case .ready:
            return "You approved this extension's server. It starts when you open a file of this kind."
        case .noServer:
            return "This extension contributes highlighting, comments and keywords for this language, and no server. There is nothing to approve."
        case .untrusted:
            return "The language works — files highlight, comments toggle, words complete from the buffer. Only the server waits: Phantom asks before starting it, the first time you open a file of this kind."
        case .needsReapproval(let reason):
            return "You approved this before, but \(reason). Phantom will ask again the next time you open a file of this kind."
        case .refused:
            return "You told Phantom not to run this server, and that answer is kept. Forgetting the decision below is the only way back — a refusal that expired on its own would be one you eventually clicked past."
        case .needsNewerApp(let declared):
            return "The manifest declares schema version \(declared), which this build cannot read. Its language half still works; its server half was discarded rather than guessed at, because a later schema is free to change what `command` means."
        case .unidentified:
            return "The manifest has no usable id, so there is nowhere for an approval to live — a trust record is keyed by identity precisely so it is not keyed by a path. The language works; the server does not."
        case .blocked(let what):
            return "Phantom will not run \(what), and will not offer to ask. A command that needs a shell, or one that resolves inside the workspace you opened, is refused outright."
        case .shadowed(let owner, let claim):
            return "\(owner) already claims \(claim), so this contribution is parsed and listed but not in effect. Copying a file into a directory must never change a language you already had."
        }
    }
}

/// The badge as the sidebar draws it: a glyph, and the sentence on hover.
struct ContributedStatusIcon: View {
    let status: ContributedStatus

    var body: some View {
        Image(systemName: status.systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(status.color)
            .help(status.title)
    }
}

/// One contributed language's detail pane.
///
/// The same shape as `LanguageServerOverrideForm` and deliberately **one
/// control short of it**: there is no Install button here, and there is no
/// path by which a string out of `extension.json` reaches the `$SHELL -lic`
/// that button runs. A manifest can say what to install; only the reader can
/// decide to type it.
struct ContributedLanguageForm: View {
    let contributed: LanguageCatalog.Contributed

    /// Not read by anything in this file, and load-bearing anyway.
    ///
    /// `LanguageTrustStore` writes to `UserDefaults` and publishes nothing,
    /// by design — a security record has no business driving a view's
    /// lifecycle. So forgetting a decision has to reach this pane some other
    /// way, and a stored property that *changes* is the way SwiftUI is told
    /// a struct view is not the same value it was: without it the parent can
    /// re-evaluate, find an identical `ContributedLanguageForm`, and skip
    /// re-running this `body` — leaving "Refused" on screen after the record
    /// behind it was dropped.
    let trustRevision: Int

    var onTrustChanged: () -> Void = {}

    @State private var showForgetConfirmation = false

    private var status: ContributedStatus {
        ContributedStatus.of(contributed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                LanguageIconView(
                    name: LSPServerDefinition.iconName(
                        forLanguageID: contributed.language.languageID
                    ),
                    size: 26
                )
                /// Every string on this screen that came out of a manifest
                /// goes through `Text(verbatim:)`. The interpolating
                /// initializer treats its argument as a `LocalizedStringKey`,
                /// which is markdown — so a display name of `**Elixir**`
                /// would render bold, and one containing `[x](javascript:…)`
                /// would render as a link. The parser escapes control
                /// scalars; it does not escape markup, because escaping for a
                /// presentation layer is the presentation layer's job.
                Text(verbatim: contributed.language.displayName)
                    .font(.title2.weight(.semibold))
                Spacer()
                statusBadge
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Form {
                Section {
                    Text(status.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Status")
                }

                extensionSection
                precedenceSection
                trustSection

                if let server = contributed.language.server {
                    serverSection(server)

                    ServerOverrideFields(
                        defaultCommand: server.command,
                        defaultArguments: server.arguments
                    )
                }
            }
            .formStyle(.grouped)
            .confirmationDialog(
                "Forget the decision for \(contributed.extensionName)?",
                isPresented: $showForgetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Forget", role: .destructive) {
                    LanguageResolver.shared.forgetTrust(
                        extensionID: contributed.provenance.extensionID
                    )
                    onTrustChanged()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Phantom will ask again the next time you open a file this extension claims.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.color)
            Text(status.title)
        }
        .font(.caption)
    }

    private var extensionSection: some View {
        Section {
            LabeledContent("Extension") {
                Text(verbatim: contributed.extensionName)
                    .textSelection(.enabled)
            }
            if !contributed.extensionVersion.isEmpty {
                LabeledContent("Version") {
                    Text(verbatim: contributed.extensionVersion)
                        .textSelection(.enabled)
                }
            }
            if !contributed.publisher.isEmpty {
                LabeledContent("Publisher") {
                    Text(verbatim: contributed.publisher)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Language ID") {
                Text(verbatim: contributed.language.languageID)
                    .textSelection(.enabled)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Origin")
                        .font(.headline)
                    Text(verbatim: contributed.manifestURL.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                /// Reveals rather than opens: this hands the file to the
                /// Finder with it selected, which is a navigation. Opening it
                /// would be Launch Services deciding what application runs for
                /// a path an extension chose.
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([contributed.manifestURL])
                }
            }
        } header: {
            Text("Extension")
        } footer: {
            Text(scopeFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var scopeFooter: String {
        switch contributed.provenance.scope {
        case .bundled:
            return "Shipped inside Phantom. Bundled extensions are trusted by origin, which assumes the app's own resources are not writable — true of an installed app, and not of a local build."
        case .user:
            return "Found in your extensions directory. Anything that can write there can change what this says, which is why the approval below is kept in your preferences and not beside the file."
        }
    }

    /// The one control `LanguagePromotionStore` and
    /// `LanguageResolver.setPromoted` both say has to exist: precedence is
    /// **compiled registry > user extension > bundled extension**, and the
    /// only way past it is a click here. A manifest cannot ask to be
    /// promoted, which is the whole reason a conflict is *shown* rather than
    /// resolved in the file's favour — so without a button the shadowed
    /// state is a dead end and the design's escape hatch does not exist.
    ///
    /// Shown only when there is something to say. An active, unpromoted
    /// contribution is already winning nothing away from anybody, and
    /// offering to promote it would invite a question the reader does not
    /// have.
    @ViewBuilder
    private var precedenceSection: some View {
        if case .shadowed(let owner, let claim) = status {
            Section {
                Button("Use This Instead of \(owner)") {
                    LanguageResolver.shared.setPromoted(
                        true,
                        extensionID: contributed.provenance.extensionID,
                        languageID: contributed.language.languageID
                    )
                }
                .disabled(contributed.provenance.extensionID.isEmpty)
            } header: {
                Text("Precedence")
            } footer: {
                Text("\(owner) claims \(claim), so this contribution is inert. Promoting it puts this extension ahead — for this language only, and until you say otherwise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if isPromoted {
            Section {
                Button("Stop Using This") {
                    LanguageResolver.shared.setPromoted(
                        false,
                        extensionID: contributed.provenance.extensionID,
                        languageID: contributed.language.languageID
                    )
                }
            } header: {
                Text("Precedence")
            } footer: {
                Text("You put this extension ahead of what Phantom ships for this language. Turning it back gives the built-in one its place again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isPromoted: Bool {
        LanguagePromotionStore.isPromoted(
            extensionID: contributed.provenance.extensionID,
            languageID: contributed.language.languageID
        )
    }

    @ViewBuilder
    private var trustSection: some View {
        Section {
            LabeledContent("Approval") {
                HStack(spacing: 5) {
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.color)
                    Text(status.title)
                }
            }

            if let record = LanguageTrustStore.record(
                for: contributed.provenance.extensionID
            ) {
                LabeledContent("Decided") {
                    Text(record.decidedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    showForgetConfirmation = true
                } label: {
                    Text("Forget Decision")
                }
            }
        } header: {
            Text("Trust")
        } footer: {
            Text("Approval gates exactly one thing: starting the server process. Everything else this extension contributes — highlighting, comments, keywords — works whether or not you ever approve it, which is what makes “Don't Run” a usable answer instead of a broken editor.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func serverSection(_ server: LanguageServerContribution) -> some View {
        Section {
            CopyableValueRow(
                title: "Default Command",
                value: ([server.command] + server.arguments).joined(separator: " ")
            )

            if !server.installHint.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("How to Install")
                            .font(.headline)
                        Text(verbatim: server.installHint)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    CopyButton(text: server.installHint, label: "Copy")
                }
            }

            if let url = server.documentationURL {
                Link(destination: url) {
                    Label("Documentation", systemImage: "book.closed")
                }
                .buttonStyle(.link)
            }
        } header: {
            Text("Server")
        } footer: {
            /// The absence of a button is the feature, so it is stated rather
            /// than left to be noticed.
            Text("Phantom does not install servers for contributed languages. The text above is the extension's own instructions, copied for you to run yourself — the Install button that compiled-in servers have is the one place a string becomes a shell command, and nothing from a manifest may reach it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
