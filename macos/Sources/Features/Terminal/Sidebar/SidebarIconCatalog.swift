import Foundation

/// The SF Symbols the icon browser offers, and the search over them.
///
/// The names live in `SidebarIconCatalogNames.swift`, generated and checked
/// in — that file says why, and what was thrown away. This one is the part
/// worth reading: how a typed query turns into an ordered list of cells.
enum SidebarIconCatalog {
    /// Split once, on first use, rather than compiled as 4173 array
    /// elements. Splitting the literal costs about a millisecond the first
    /// time the browser opens; asking the type checker to infer 4173 element
    /// types costs every build.
    static let all: [String] = names.split(separator: "\n").map(String.init)

    /// The catalogue narrowed to `query`, best guesses first.
    ///
    /// A symbol name is a dotted path — `arrow.up.circle` — and a reader
    /// searching it does not know which component they remember. So every
    /// token has to match anywhere in the name: "arrow" finds
    /// `arrow.up.circle`, "circle" finds it too, and "arrow circle" finds it
    /// while "arrow trash" finds nothing.
    ///
    /// Substring matching alone is too generous to browse — "up" also
    /// catches `cup`, `group`, `backup` — so the results are bucketed rather
    /// than filtered further. A name with a component that *is* the first
    /// token comes before one where the token merely starts a component,
    /// which comes before one where it is buried mid-word. Nothing is
    /// dropped; the noise just sinks.
    ///
    /// Order inside a bucket is Apple's own catalogue order, which keeps
    /// `arrow.up`, `arrow.up.circle` and `arrow.up.square` adjacent instead
    /// of scattering them alphabetically.
    static func matches(_ query: String) -> [String] {
        let tokens = tokens(in: query)
        guard let head = tokens.first else { return all }

        var isComponent: [String] = []
        var startsComponent: [String] = []
        var buried: [String] = []

        for name in all where tokens.allSatisfy({ name.contains($0) }) {
            let components = name.split(separator: ".")
            if components.contains(where: { $0 == head }) {
                isComponent.append(name)
            } else if components.contains(where: { $0.hasPrefix(head) }) {
                startsComponent.append(name)
            } else {
                buried.append(name)
            }
        }

        return isComponent + startsComponent + buried
    }

    /// The separators of a symbol name are also the ones a reader types, so
    /// "arrow.up", "arrow up" and "arrow-up" are the same two tokens.
    private static func tokens(in query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { " .-_".contains($0) })
            .map(String.init)
    }
}
