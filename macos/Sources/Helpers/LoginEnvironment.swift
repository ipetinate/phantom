import Foundation

/// The `PATH` the user's own shell would have, for subprocesses that run
/// the user's tooling.
///
/// A GUI app launched from Finder or the Dock gets `launchd`'s environment,
/// which on this machine means `PATH=/usr/bin:/bin:/usr/sbin:/sbin` —
/// no Homebrew, no nvm, no pnpm. That's fine for `git status`, and quietly
/// fatal for anything that runs a hook: a `git commit` in a repo with husky
/// spawns `.husky/pre-commit`, which calls `npx`, which isn't on that path.
/// The commit fails with `npx: command not found` and no obvious cause.
///
/// So the login shell is asked once, in the background, what its `PATH` is,
/// and git subprocesses inherit that instead.
///
/// Only `PATH` is taken, deliberately. Importing a login shell's entire
/// environment into a long-lived GUI process means inheriting whatever a
/// dotfile happened to export this session — the class of leakage
/// `InheritedEnvironment` exists to clean up in the other direction.
enum LoginEnvironment {
    /// A login shell has to source the user's rc files to build `PATH`, and
    /// people put slow things in those.
    private static let resolveTimeout: TimeInterval = 5

    private static let lock = NSLock()
    private static var cachedPath: String?
    private static var didResolve = false

    /// Serializes the resolution itself, so concurrent callers share one
    /// login shell rather than each starting their own. Separate from
    /// `lock`, which guards only the cached value and is never held across
    /// the subprocess.
    private static let resolveQueue = DispatchQueue(label: "phantom.login-environment.resolve")

    /// The environment to hand a subprocess: the current one with `PATH`
    /// replaced, when the login shell's could be resolved.
    ///
    /// Falls back to the process environment unchanged rather than failing
    /// — a wrong `PATH` breaks hooks, but no environment at all breaks
    /// everything.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let path = loginPath() { env["PATH"] = path }
        return env
    }

    /// The environment for a subprocess that runs developer tooling: the
    /// login shell's `PATH` plus the directories where package managers
    /// install user binaries (`GOBIN`, `~/go/bin`, …).
    ///
    /// A server's own subprocesses inherit this, so a tool the server shells
    /// out to benefits too, not just the executable `Process` launches
    /// directly.
    static func executableEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = executableSearchPath()
        return env
    }

    /// Throws the cached `PATH` away so the next read resolves again.
    ///
    /// Resolving costs a login shell, so it is cached for the life of the
    /// process — and that is a cache nobody was invalidating. A version
    /// manager rewrites `PATH` from `.zshrc`, so `nvm use` moves the bin
    /// directory and every lookup afterwards keeps searching the old one
    /// until the app is restarted. Callers that fail to find something they
    /// expected should invalidate and try once more.
    static func invalidate() {
        lock.lock()
        didResolve = false
        cachedPath = nil
        lock.unlock()
    }

    /// Resolves and caches the login shell's `PATH`. Blocking; call from a
    /// background task.
    ///
    /// Callers that arrive while a resolution is in flight wait for it
    /// rather than starting their own. The lock only ever guarded the
    /// *cache*, not the work: everyone who asked before the first answer
    /// landed saw `didResolve == false` and ran their own login shell.
    /// Restoring a session asks all at once — every surface and every
    /// language server wants the path — so a dozen interactive shells
    /// started together, each sourcing the whole of `.zshrc`. The machine
    /// spends its time on that instead of on the terminals that were being
    /// restored, which is what makes them come back unresponsive.
    static func loginPath() -> String? {
        if let cached = cachedResult() { return cached }

        // Serialized so the shell runs once. The second check inside is
        // what makes everyone queued behind the first caller take its
        // answer instead of repeating the work.
        return resolveQueue.sync {
            if let cached = cachedResult() { return cached }

            let resolved = resolve()

            lock.lock()
            cachedPath = resolved
            didResolve = true
            lock.unlock()

            return resolved
        }
    }

    /// The cached path, or nil when nothing has been resolved yet.
    ///
    /// A resolution that *failed* is still a resolution: it is cached as a
    /// nil path with `didResolve` set, so a machine where the login shell
    /// cannot answer does not pay for it again on every call.
    private static func cachedResult() -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return didResolve ? .some(cachedPath) : nil
    }

    /// Search path for tools installed outside the login shell's PATH.
    ///
    /// Go installs user binaries in GOBIN or GOPATH/bin by default. GUI apps
    /// are often launched without the shell configuration that contains
    /// those directories, so LSPs such as gopls would otherwise appear to be
    /// missing even after `go install` succeeds.
    static func executableSearchPath() -> String {
        var directories: [String] = []
        if let path = loginPath() {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }

        let environment = ProcessInfo.processInfo.environment
        if let gobin = environment["GOBIN"], !gobin.isEmpty {
            directories.append(gobin)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let gopath = environment["GOPATH"] ?? "\(home)/go"
        directories.append(contentsOf: gopath.split(separator: ":").map { "\($0)/bin" })
        directories.append("\(home)/go/bin")

        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    private static func resolve() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        // Interactive as well as login: plenty of people set PATH in
        // .zshrc rather than .zprofile, and a login-only shell misses it.
        let result = ShellCommand.runResult(
            shell,
            ["-lic", "printf %s \"$PATH\""],
            timeout: resolveTimeout
        )

        guard result.succeeded else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
