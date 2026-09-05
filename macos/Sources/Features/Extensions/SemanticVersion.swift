import Foundation

struct SemanticVersion: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap(Self.component)
        guard numbers.count == 3 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    static func isValid(_ text: String) -> Bool {
        SemanticVersion(text) != nil
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    private static func component(_ part: Substring) -> Int? {
        guard !part.isEmpty, part.count <= 9 else { return nil }
        guard part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(part)
    }
}
