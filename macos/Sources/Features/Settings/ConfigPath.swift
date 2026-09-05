import Foundation

struct ConfigPath: Equatable, Sendable, ExpressibleByStringLiteral {
    let candidates: [String]

    init(_ candidates: [String]) {
        self.candidates = candidates
    }

    init(stringLiteral value: String) {
        self.candidates = [value]
    }

    static func isEnvironmentReference(_ candidate: String) -> Bool {
        candidate.hasPrefix("$")
    }

    static func expand(
        _ candidate: String,
        environment: [String: String],
        home: URL
    ) -> String? {
        if candidate == "~" { return home.path }
        if candidate.hasPrefix("~/") {
            return home.appendingPathComponent(String(candidate.dropFirst(2))).path
        }
        guard isEnvironmentReference(candidate) else { return candidate }

        let body = candidate.dropFirst()
        let name = String(body.prefix { $0 != "/" })
        let remainder = String(body.dropFirst(name.count))
        guard let value = environment[name], !value.isEmpty else { return nil }
        return value + remainder
    }

    func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        for (index, candidate) in candidates.enumerated() {
            guard let path = Self.expand(candidate, environment: environment, home: home) else {
                continue
            }
            let isLast = index == candidates.count - 1
            if isLast || Self.isEnvironmentReference(candidate) || exists(path) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return home
    }
}
