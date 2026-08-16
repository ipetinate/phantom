import Foundation

/// Picks the JVM a Java-based language server runs *itself* on, without
/// deciding which JVM that server's build tool will use.
///
/// Those are two questions, and handing the server the login shell's
/// environment answers both with one value. `JAVA_HOME` is normally set to
/// the JDK a developer builds with — the newest one — and a language server
/// inherits it. When the server cannot run on that JDK it dies during
/// launch: `kotlin-language-server` 1.3.13 bundles a Kotlin compiler whose
/// IntelliJ core throws `IllegalArgumentException: 25.0.3` while parsing the
/// version of a JDK 25, and exits before answering `initialize`. From the
/// editor's side that is indistinguishable from a server that was never
/// installed.
///
/// Lowering `JAVA_HOME` on its own trades that failure for a quieter one.
/// These servers do not resolve a project's classpath themselves — they
/// shell out to the project's build tool, which reads the same variable. A
/// Gradle build whose daemon needs a newer JDK than the server can run on
/// then fails to start, the classpath comes back empty, and every import in
/// the project is reported unresolved with no visible reason. So the
/// inherited value is not discarded here: the server alone is moved, and
/// the JDK the environment asked for is handed back to Gradle explicitly.
///
/// Nothing in this file knows anything about a particular project. The only
/// input that isn't discovered from the machine is the ceiling the server
/// declares in the registry, which is a fact about the compiler that server
/// bundles — not about what it is pointed at.
enum LSPJavaRuntime {
    /// A directory that holds JDKs, and how deep inside it they sit.
    struct SearchRoot: Sendable, Equatable {
        let path: String

        /// Directory levels between a child of `path` and the JDK itself.
        /// Zero for every installer that puts the JDK — or its `.jdk`
        /// bundle — directly under the root. One for Gradle's
        /// auto-provisioned JDKs, which nest the bundle inside a directory
        /// named after the request that downloaded it.
        var nesting: Int = 0
    }

    /// The environment to launch `definition` with, given the one the login
    /// shell provided.
    ///
    /// Returns its input untouched in every case where the answer is not
    /// clearly an improvement: a server that declares no ceiling, an
    /// environment naming no JDK, a JDK already low enough, or a machine
    /// with nothing older installed. That last one matters — with no
    /// replacement to offer, leaving `JAVA_HOME` alone keeps the failure the
    /// server's own, which is the failure whose message names a fix.
    static func adjustedEnvironment(
        _ environment: [String: String],
        for definition: LSPServerDefinition,
        installedHomes: () -> [String] = { installedJavaHomes() },
        fileManager: FileManager = .default
    ) -> [String: String] {
        guard let ceiling = definition.maximumJavaFeatureVersion,
              let inherited = environment["JAVA_HOME"], !inherited.isEmpty,
              let inheritedVersion = featureVersion(ofJavaHome: inherited, fileManager: fileManager),
              inheritedVersion > ceiling,
              let replacement = newestJavaHome(upTo: ceiling, among: installedHomes(), fileManager: fileManager)
        else { return environment }

        var adjusted = environment
        adjusted["JAVA_HOME"] = replacement
        adjusted["GRADLE_OPTS"] = gradleOptions(
            preserving: inherited,
            in: environment["GRADLE_OPTS"]
        )
        return adjusted
    }

    /// `GRADLE_OPTS` carrying the JDK this app just moved off `JAVA_HOME`.
    ///
    /// Only ever called after an override, because that is the only thing it
    /// undoes. An existing `org.gradle.java.home` is left alone: it was put
    /// there by the developer, and this is not a preference — it is
    /// compensation for one.
    ///
    /// A project that states its own daemon JDK — `gradle-daemon-jvm.properties`,
    /// or a toolchain — outranks this property in Gradle's own precedence, so
    /// a build that already knows what it needs is unaffected either way.
    static func gradleOptions(preserving inheritedJavaHome: String, in existing: String?) -> String {
        let existing = existing ?? ""
        guard !existing.contains(daemonJavaHomeProperty) else { return existing }

        // `gradlew` word-splits this variable, so a path with a space in it
        // has to survive as one argument. Quoting unconditionally would be
        // simpler and would leak quotes into anything that reads the
        // variable without a shell.
        let value = inheritedJavaHome.contains(" ") ? "\"\(inheritedJavaHome)\"" : inheritedJavaHome
        let injected = "-D\(daemonJavaHomeProperty)=\(value)"
        return existing.isEmpty ? injected : "\(injected) \(existing)"
    }

    /// The highest-versioned JDK that is still at or below `ceiling`.
    ///
    /// Highest rather than any, because the ceiling says what the server
    /// cannot read, not what it prefers — and a JDK 8 lying around should
    /// not win over a JDK 21 when the server tops out at 21. Ties break on
    /// the path so the choice doesn't change between launches.
    static func newestJavaHome(
        upTo ceiling: Int,
        among homes: [String],
        fileManager: FileManager = .default
    ) -> String? {
        homes
            .compactMap { home -> (path: String, version: Int)? in
                guard let version = featureVersion(ofJavaHome: home, fileManager: fileManager),
                      version <= ceiling else { return nil }
                return (home, version)
            }
            .sorted { left, right in
                left.version == right.version ? left.path < right.path : left.version > right.version
            }
            .first?.path
    }

    /// Every JDK this machine has, in the places the tools that install JDKs
    /// put them.
    ///
    /// Read from the directories directly rather than asked of
    /// `/usr/libexec/java_home`, which only knows about
    /// `/Library/Java/JavaVirtualMachines` — on a machine whose JDKs all came
    /// from Homebrew it reports that no Java runtime is installed at all,
    /// while three of them sit under `/opt/homebrew/opt`.
    static func installedJavaHomes(
        searchRoots: [SearchRoot] = defaultSearchRoots(),
        fileManager: FileManager = .default
    ) -> [String] {
        searchRoots.flatMap { root -> [String] in
            guard let children = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
            return children.sorted().compactMap { child in
                javaHome(
                    under: (root.path as NSString).appendingPathComponent(child),
                    nesting: root.nesting,
                    fileManager: fileManager
                )
            }
        }
    }

    /// Where JDKs land, by installer rather than by vendor.
    ///
    /// Both Homebrew prefixes are listed because a machine can be either
    /// architecture and the cost of a directory that isn't there is one
    /// failed read.
    static func defaultSearchRoots(homeDirectory: String = NSHomeDirectory()) -> [SearchRoot] {
        let home = homeDirectory as NSString
        return [
            SearchRoot(path: "/Library/Java/JavaVirtualMachines"),
            SearchRoot(path: home.appendingPathComponent("Library/Java/JavaVirtualMachines")),
            SearchRoot(path: "/opt/homebrew/opt"),
            SearchRoot(path: "/usr/local/opt"),
            SearchRoot(path: home.appendingPathComponent(".sdkman/candidates/java")),
            SearchRoot(path: home.appendingPathComponent(".asdf/installs/java")),
            SearchRoot(path: home.appendingPathComponent(".local/share/mise/installs/java")),
            SearchRoot(path: home.appendingPathComponent(".gradle/jdks"), nesting: 1)
        ]
    }

    /// The feature version of the JDK at `home` — 21 for `21.0.12`, 8 for
    /// `1.8.0_452`.
    ///
    /// Read out of the `release` file every JDK ships rather than by running
    /// `java -version`. This is on the path that starts a language server,
    /// and spawning a JVM to ask a JDK its own version would put a process
    /// launch in front of every server start for an answer already sitting
    /// in a text file.
    static func featureVersion(ofJavaHome home: String, fileManager: FileManager = .default) -> Int? {
        let releaseFile = (home as NSString).appendingPathComponent("release")
        guard let contents = try? String(contentsOfFile: releaseFile, encoding: .utf8) else { return nil }

        for line in contents.split(separator: "\n") where line.hasPrefix("JAVA_VERSION=") {
            let raw = line
                .dropFirst("JAVA_VERSION=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" \r"))
            return featureVersion(ofVersionString: raw)
        }
        return nil
    }

    /// The feature version named by a JDK version string.
    ///
    /// Handles the pre-9 spelling — `1.8.0_452` is Java 8, not Java 1 — so
    /// an old JDK on the machine can't be read as the lowest possible
    /// version and win a comparison it should lose.
    static func featureVersion(ofVersionString version: String) -> Int? {
        let parts = version.split(separator: ".")
        guard let first = parts.first, let major = Int(first) else { return nil }
        guard major == 1 else { return major }
        guard parts.count > 1 else { return nil }
        return Int(parts[1])
    }

    private static let daemonJavaHomeProperty = "org.gradle.java.home"

    /// The JDK home inside `directory`, whichever shape the installer used:
    /// the directory itself (SDKMAN, asdf, mise), a macOS bundle
    /// (`.jdk/Contents/Home`), or Homebrew's keg layout. `nesting` allows one
    /// more level for roots whose children are directories *of* bundles.
    ///
    /// Presence of `bin/java` is the test, not the shape of the name — a
    /// directory that looks like a JDK and cannot execute one is not a JDK,
    /// and a partially-extracted download is exactly that.
    private static func javaHome(
        under directory: String,
        nesting: Int,
        fileManager: FileManager
    ) -> String? {
        let candidates = [
            directory,
            (directory as NSString).appendingPathComponent("Contents/Home"),
            (directory as NSString).appendingPathComponent("libexec/openjdk.jdk/Contents/Home")
        ]
        for candidate in candidates {
            let executable = (candidate as NSString).appendingPathComponent("bin/java")
            if fileManager.isExecutableFile(atPath: executable) { return candidate }
        }

        guard nesting > 0,
              let children = try? fileManager.contentsOfDirectory(atPath: directory)
        else { return nil }

        for child in children.sorted() {
            let nested = (directory as NSString).appendingPathComponent(child)
            if let home = javaHome(under: nested, nesting: nesting - 1, fileManager: fileManager) {
                return home
            }
        }
        return nil
    }
}
