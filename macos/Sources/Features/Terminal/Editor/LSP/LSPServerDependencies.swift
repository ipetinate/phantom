import Foundation

/// One package a server needs on this machine, and the sentence saying when.
///
/// **Only this file can build one**, and that is a security property rather
/// than tidiness. A value of this type is the only thing
/// `LSPServerDefinition.installCommand(forDependencies:)` will put into the
/// string it hands to `$SHELL -lic`, so an initializer unreachable from
/// outside means that shell line can be assembled from nothing but the
/// literals in `LSPDependencyCatalog` below — not from a manifest, not from a
/// caller written next year that meant well.
struct LSPServerDependency: Hashable, Sendable, Identifiable {
    /// What puts the package there.
    ///
    /// One case today. An enum rather than an assumption because the composer
    /// joins specs into a single command line: a Homebrew dependency added
    /// later must not be able to ride along on an `npm i -g` that never had to
    /// ask what installer it was serving.
    enum Installer: Hashable, Sendable {
        case npmGlobal
    }

    /// How to tell whether the package is already here.
    ///
    /// The rule for choosing between them is **check what Phantom itself
    /// consumes**. A package the app reaches by spawning a binary is checked
    /// on the login `PATH`, because that is exactly what a launch does; a
    /// package the app reaches by reading a directory under `npm root -g` is
    /// checked there, because a binary on `PATH` would prove nothing about it.
    /// `@vue/typescript-plugin` ships no binary at all, and only the second
    /// kind can see it — which is why a single "is the command there" probe
    /// could never have answered this question.
    enum Presence: Hashable, Sendable {
        /// Locatable on the login `PATH` under this name — the same fact
        /// `LSPCenter.installedCommands` already probes, so this costs nothing
        /// extra.
        case binary(String)

        /// A directory under `npm root -g`. Costs one subprocess for the whole
        /// screen; see `LSPDependencyCenter`.
        case globalPackage
    }

    /// The npm package name, unpinned — also the identity, so a pin bump does
    /// not read as a different dependency.
    let package: String

    /// The version this app installs, or nil when any version will do.
    ///
    /// A bare major (`"6"`) is satisfied by any release in that major; a full
    /// version (`"3.3.10"`) has to match exactly, which is what "in lockstep"
    /// requires.
    let pin: String?

    /// The sentence saying *when* this package is needed. It is the entire
    /// reason a global Settings screen can talk about dependencies at all:
    /// it has no project in context, so it can only explain the rule.
    let purpose: String

    let installer: Installer
    let presence: Presence

    var id: String { package }

    /// What goes on the install command line.
    var spec: String {
        guard let pin else { return package }
        return "\(package)@\(pin)"
    }

    /// Whether a version found on disk is the one this app pinned.
    func satisfies(version: String) -> Bool {
        guard let pin else { return true }
        if pin.contains(".") { return version == pin }
        return version.split(separator: ".").first.map(String.init) == pin
    }

    /// Module-visible rather than file-private so a test can build a fixture.
    /// `satisfies(version:)` accepts a major-only pin, and no plan in the table
    /// uses one any more — the last was the TypeScript wrapper's `typescript@6`,
    /// which left because it collided with the native TypeScript row. Without a
    /// fixture that branch would be exercised by nothing at all.
    init(
        package: String,
        pin: String? = nil,
        purpose: String,
        installer: Installer = .npmGlobal,
        presence: Presence
    ) {
        self.package = package
        self.pin = pin
        self.purpose = purpose
        self.installer = installer
        self.presence = presence
    }
}

/// Everything one server's Install popover shows.
///
/// The note travels with the packages rather than living in a second table
/// keyed by the same command, because the two are one thought — "here is what
/// this machine needs, and here is the part this screen cannot answer" — and
/// two tables are two things to keep in step.
struct LSPServerDependencyPlan: Hashable, Sendable {
    let packages: [LSPServerDependency]

    /// What Settings is not in a position to promise.
    ///
    /// This screen is global: it has no workspace, so it may explain the rule
    /// and may not claim to know what a project needs. The note is where that
    /// boundary is said out loud, and it points at the editor's own banner —
    /// which does have a root and does answer the case.
    let projectNote: String?
}

/// Whether a dependency is here, and whether it is the version this app pinned.
enum LSPDependencyStatus: Hashable, Sendable {
    /// The probe has not answered yet. Distinct from `missing` on purpose:
    /// guessing "missing" for the second it takes is how a reader ends up
    /// reinstalling something they already have.
    case unknown

    case missing

    /// Here, but not at the pinned version — which for the Vue pair is the
    /// failure this popover exists to prevent, not a lesser one than absence.
    case outdated(installed: String)

    case present

    /// Whether the popover should tick this one by default.
    var needsInstall: Bool {
        switch self {
        case .missing, .outdated: return true
        case .unknown, .present: return false
        }
    }
}

/// The table of what each built-in server needs beyond its own binary.
enum LSPDependencyCatalog {
    /// `@vue/language-server` and `@vue/typescript-plugin` are built and
    /// published together out of `vuejs/language-tools`, and the plugin's
    /// protocol with the server is not versioned separately. A machine that
    /// installed one of them months ago and the other today gets 2.2.12 beside
    /// 3.3.10, which is the skew this whole popover exists to prevent — so the
    /// two rows read the same constant and cannot drift apart even in source.
    ///
    /// Bump both by bumping this.
    private static let vueToolsVersion = "3.3.10"

    /// The `@6` is a bridge, not a permanent pin. TypeScript 7 is the native
    /// rewrite and speaks LSP itself — see `TypeScriptToolchain` — so when the
    /// routing prefers the native binary everywhere, this dependency stops
    /// existing rather than moving to `@7`. Pinning `latest` today installs 7,
    /// which ships no `tsserver.js` and leaves the wrapper with nothing to
    /// drive.
    private static let tsserverCompatibleTypeScript = "6"

    /// **The TypeScript wrapper has no plan on purpose.** It used to list a
    /// global `typescript@6` beside itself, and that package is the one the
    /// native row installs as *itself* at version 7 — so installing either row
    /// changed the other, which is the crossing that got reported. The plan's
    /// own note said why it was unnecessary: a file reaches the wrapper only
    /// when its project has `node_modules/typescript`, and a project without
    /// one is served by `tsc --lsp`. So the dependency was never needed for
    /// routing, only for a case routing does not produce.
    ///
    /// Dropping it also settles the shape of the row. A server with a plan
    /// draws the multi-package popover *and* an Uninstall button side by side;
    /// without one it draws a plain Install or Uninstall, which is what two
    /// clearly-labelled rows want.
    private static let plans: [String: LSPServerDependencyPlan] = [
        "vue-language-server": LSPServerDependencyPlan(
            packages: [
                LSPServerDependency(
                    package: "@vue/language-server",
                    pin: vueToolsVersion,
                    purpose: """
                    Serves the <template> and <style> blocks of every .vue \
                    file. This row's own server.
                    """,
                    presence: .binary("vue-language-server")
                ),
                LSPServerDependency(
                    package: "@vue/typescript-plugin",
                    pin: vueToolsVersion,
                    purpose: """
                    Needed for the <script> block, which \
                    typescript-language-server serves rather than the Vue \
                    server — this plugin is what registers Vue with it. \
                    Pinned to the version above: the two are published \
                    together and a mismatched pair fails without either \
                    reporting it.
                    """,
                    presence: .globalPackage
                ),
                LSPServerDependency(
                    package: "typescript-language-server",
                    purpose: """
                    The process that loads the plugin. A .vue file is served \
                    by two servers, and this is the second one.
                    """,
                    presence: .binary("typescript-language-server")
                ),
            ],
            projectNote: """
            Phantom loads the plugin and tsserver.js from the project being \
            edited, not from here. Opening a .vue file reports which \
            TypeScript that project has and whether its <script> block can be \
            served at all.
            """
        ),
    ]

    /// The plan for a built-in command, or nil for a server whose one install
    /// command is the whole story.
    ///
    /// Keyed on the command rather than the language id for the same reason
    /// `uninstallCommand` is: four language ids share the TypeScript binary
    /// and one `.vue` file needs two different binaries, so the binary is the
    /// only key that names the thing being installed.
    static func plan(forCommand command: String) -> LSPServerDependencyPlan? {
        plans[command]
    }

    /// Every npm package any plan names, for the probe to look up in one pass.
    static var allPackages: [String] {
        var seen: Set<String> = []
        return plans.values
            .flatMap(\.packages)
            .filter { seen.insert($0.package).inserted }
            .map(\.package)
            .sorted()
    }

    // MARK: What is here

    /// The status of one dependency against a probed machine.
    ///
    /// Pure — the probing happened elsewhere and arrives as two values — so
    /// the rule can be tested without a shell, an npm, or a filesystem.
    static func status(
        of dependency: LSPServerDependency,
        installedCommands: Set<String>,
        globalVersions: [String: String]
    ) -> LSPDependencyStatus {
        let installedVersion = globalVersions[dependency.package]

        switch dependency.presence {
        case .binary(let name):
            guard installedCommands.contains(name) else { return .missing }
        case .globalPackage:
            guard installedVersion != nil else { return .missing }
        }

        /// No readable version is not the same as a wrong one. A binary
        /// installed from somewhere other than the global npm prefix — a
        /// version manager, Homebrew, a project's own `bin` — is genuinely
        /// there, and calling it outdated because this app could not read a
        /// `package.json` beside it would be a lie with an install button
        /// under it.
        guard let installedVersion else { return .present }
        return dependency.satisfies(version: installedVersion)
            ? .present
            : .outdated(installed: installedVersion)
    }

    static func statuses(
        for plan: LSPServerDependencyPlan,
        installedCommands: Set<String>,
        globalVersions: [String: String]
    ) -> [String: LSPDependencyStatus] {
        var result: [String: LSPDependencyStatus] = [:]
        for dependency in plan.packages {
            result[dependency.id] = status(
                of: dependency,
                installedCommands: installedCommands,
                globalVersions: globalVersions
            )
        }
        return result
    }

    /// Which boxes are ticked when the popover opens: the ones this machine
    /// is missing, plus the ones whose installed version is not the pin.
    ///
    /// It cannot tick "the ones this project needs", because this screen has
    /// no project — see `LSPServerDependencyPlan.projectNote`.
    static func defaultSelection(
        for plan: LSPServerDependencyPlan,
        statuses: [String: LSPDependencyStatus]
    ) -> Set<String> {
        Set(
            plan.packages
                .filter { (statuses[$0.id] ?? .unknown).needsInstall }
                .map(\.id)
        )
    }

    // MARK: Composing the command

    /// The characters an npm spec may contain.
    ///
    /// The composed line goes to `$SHELL -lic`, so a spec is concatenated into
    /// a shell command with no quoting around it. Every spec in the table is a
    /// literal in this file and none of them needs anything outside this set —
    /// which is exactly why refusing the rest costs nothing and closes the
    /// question permanently. `LSPServerDependencyTests` walks the whole table
    /// through it.
    private static let allowedSpecCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._/-"
    )

    static func isShellSafe(_ spec: String) -> Bool {
        !spec.isEmpty && spec.allSatisfy { allowedSpecCharacters.contains($0) }
    }

    /// One command line installing all of them, or nil when there is nothing
    /// to install or something in the list has no business on a shell line.
    ///
    /// Grouped by installer and joined with `&&` so that a future dependency
    /// installed by something other than npm produces two commands rather than
    /// one nonsensical one.
    static func command(for dependencies: [LSPServerDependency]) -> String? {
        guard !dependencies.isEmpty else { return nil }
        guard dependencies.allSatisfy({ isShellSafe($0.spec) }) else { return nil }

        var order: [LSPServerDependency.Installer] = []
        var specs: [LSPServerDependency.Installer: [String]] = [:]
        for dependency in dependencies {
            if specs[dependency.installer] == nil { order.append(dependency.installer) }
            specs[dependency.installer, default: []].append(dependency.spec)
        }

        let lines = order.compactMap { installer -> String? in
            guard let group = specs[installer], !group.isEmpty else { return nil }
            switch installer {
            case .npmGlobal:
                return "npm i -g " + group.joined(separator: " ")
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: " && ")
    }

    // MARK: Reading the machine

    /// The versions of `packages` installed under a global `node_modules`.
    ///
    /// Split from the subprocess above it so the part with a rule in it can be
    /// tested against a directory a test built, rather than against whatever
    /// npm happens to have put on the machine running the suite.
    static func versions(
        of packages: [String],
        inNodeModules root: String,
        fileManager: FileManager = .default
    ) -> [String: String] {
        var found: [String: String] = [:]
        for package in packages {
            let manifest = (root as NSString)
                .appendingPathComponent(package)
                .appending("/package.json")
            guard let data = fileManager.contents(atPath: manifest),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String,
                  !version.isEmpty
            else { continue }
            found[package] = version
        }
        return found
    }

    /// `npm root -g` rather than guessing at Homebrew/nvm/volta layouts, for
    /// the same reason `LSPInitializationOptions` does it: npm knows where it
    /// put things and a guess is wrong for exactly the setups a guess is
    /// hardest to get right for.
    ///
    /// **Blocks on a subprocess**, so it belongs on a background task and
    /// never inside a view's `body` — see `LSPDependencyCenter.refresh()`.
    ///
    /// **Nil when the probe could not run, and that is the point.** It used to
    /// answer `[:]`, which is also what a machine with none of these packages
    /// answers — so a probe that failed was indistinguishable from a truthful
    /// "nothing is installed". Reported: right after installing the Vue pair,
    /// the pane said the server was not installed, would not leave the Install
    /// state, and offered to install `typescript-language-server`, which had
    /// been there all along. `npm root -g` had simply not answered inside its
    /// budget on a machine still busy from the install that had just finished.
    ///
    /// A failure to measure is not a measurement. The caller keeps its last
    /// good answer and stays `.unknown` rather than claiming absence.
    static func globalVersions(of packages: [String]) -> [String: String]? {
        guard !packages.isEmpty else { return [:] }
        let searchPath = LoginEnvironment.executableSearchPath()
        guard let npm = LSPProcess.locate("npm", searchPath: searchPath) else { return nil }
        guard let output = ShellCommand.run(npm, ["root", "-g"], timeout: probeTimeout)
        else { return nil }

        let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        return versions(of: packages, inNodeModules: root)
    }

    /// How long `npm root -g` gets to answer.
    ///
    /// Twenty seconds, up from five. npm's own startup under a version manager
    /// is most of a second when the machine is idle, and this probe runs at the
    /// worst possible moment for it: immediately after an install, with the
    /// disk still settling. Five seconds was measured being missed there.
    ///
    /// Generous rather than tight, because nothing waits on this. It runs on a
    /// background task and the pane shows the previous answer until it lands —
    /// so the cost of a long budget is a stale row for a few seconds, and the
    /// cost of a short one is a row that lies.
    static let probeTimeout: TimeInterval = 20
}

extension LSPServerDefinition {
    /// What this server needs beyond its own binary, or nil when its single
    /// install command says everything there is to say.
    ///
    /// **Nil for anything a manifest contributed**, and that refusal is the
    /// reason to read this rather than `LSPDependencyCatalog` directly. It is
    /// the same guard `installCommand` carries and for the same reason: the
    /// packages here become a string handed to `$SHELL -lic`. A contributed
    /// definition is free to name itself `vue-language-server`, and a lookup
    /// keyed on the command alone would hand it this plan — which is the
    /// mistake `uninstallCommand` already made once, when a manifest calling
    /// itself `rust-analyzer` was offered `rustup component remove`.
    var dependencyPlan: LSPServerDependencyPlan? {
        guard case .builtIn = origin else { return nil }
        return LSPDependencyCatalog.plan(forCommand: command)
    }

    /// The shell command installing the chosen dependencies, or nil when
    /// there is nothing this app may run.
    ///
    /// `selected` is a set of ids and not a set of packages, so the worst a
    /// confused caller can pass is a name that matches nothing: the filter
    /// keeps only members of this server's own plan, in the plan's order, and
    /// an unrecognised id selects nothing rather than adding a word to a
    /// shell line.
    func installCommand(forDependencies selected: Set<String>) -> String? {
        guard case .builtIn = origin else { return nil }
        guard let plan = dependencyPlan else { return nil }
        let chosen = plan.packages.filter { selected.contains($0.id) }
        return LSPDependencyCatalog.command(for: chosen)
    }
}
