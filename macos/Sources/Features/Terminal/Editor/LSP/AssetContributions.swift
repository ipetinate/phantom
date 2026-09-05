import Foundation

typealias SyntaxContribution = LanguageSyntax.Patterns

extension SyntaxContribution {
    static let maxPatternLength = 2048

    static let presets: [String: String] = [
        "number": SyntaxRules.number,
        "cStyleString": SyntaxRules.cStyleString,
        "capitalizedType": SyntaxRules.capitalizedType,
        "callBeforeParen": SyntaxRules.callBeforeParen,
        "callBeforeParenOrGeneric": SyntaxRules.callBeforeParenOrGeneric,
    ]

    static let presetPrefix = "preset:"

    static func parse(json: Any?) -> SyntaxContribution {
        guard let json = json as? [String: Any] else { return SyntaxContribution() }
        return SyntaxContribution(
            string: pattern(json["string"]),
            number: pattern(json["number"]),
            type: pattern(json["type"]),
            function: pattern(json["function"]),
            attribute: pattern(json["attribute"])
        )
    }

    static func pattern(_ value: Any?) -> String? {
        guard let raw = LanguageManifest.string(value) else { return nil }
        if raw.hasPrefix(presetPrefix) {
            return presets[String(raw.dropFirst(presetPrefix.count))]
        }
        guard raw.count <= maxPatternLength, isSafePattern(raw) else { return nil }
        guard (try? NSRegularExpression(pattern: raw, options: [.anchorsMatchLines])) != nil else {
            return nil
        }
        return raw
    }

    static func isSafePattern(_ pattern: String) -> Bool {
        let scalars = Array(pattern.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\" {
                guard index + 1 < scalars.count else { return false }
                let escaped = scalars[index + 1]
                if ("1"..."9").contains(escaped) || escaped == "k" { return false }
                index += 2
                continue
            }
            if scalar == "(", index + 2 < scalars.count,
               scalars[index + 1] == "?", scalars[index + 2] == "<" {
                let opener: Unicode.Scalar? = index + 3 < scalars.count ? scalars[index + 3] : nil
                guard opener == "=" || opener == "!" else { return false }
            }
            index += 1
        }
        return true
    }
}

struct FormatterContribution: Equatable, Sendable {
    let id: String
    let name: String
    let command: String
    let arguments: [String]
    let fileExtensions: [String]
    let installHint: String
    let documentationURL: URL?

    static let maxFormatters = 32

    static func parse(json: [String: Any]) -> FormatterContribution? {
        guard let id = validID(json["id"]) else { return nil }
        guard let command = LanguageManifest.string(json["command"]),
              LanguageServerContribution.isLaunchable(command)
        else { return nil }
        let fileExtensions = LanguageContribution.fileExtensions(from: json["extensions"])
        guard !fileExtensions.isEmpty else { return nil }

        let arguments = (json["args"] as? [Any])?
            .compactMap { $0 as? String }
            .filter { !$0.unicodeScalars.contains(where: LanguageContribution.isUnsafeScalar) }
            .prefix(LanguageServerContribution.maxArguments)
            .map { $0 } ?? []

        return FormatterContribution(
            id: id,
            name: LanguageManifest.displayString(json["name"]) ?? id,
            command: command,
            arguments: arguments,
            fileExtensions: fileExtensions,
            installHint: LanguageServerContribution.installHint(json["installHint"]),
            documentationURL: LanguageServerContribution.documentationURL(json["documentationURL"])
        )
    }

    static func validID(_ value: Any?) -> String? {
        guard let raw = LanguageManifest.string(value), raw.count <= 64 else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        guard raw.allSatisfy(allowed.contains) else { return nil }
        return raw
    }
}

struct ThemeContribution: Equatable, Sendable {
    enum Appearance: String, Equatable, Sendable {
        case dark
        case light
    }

    let name: String
    let fileURL: URL
    let appearance: Appearance?

    static let maxThemes = 64

    static let maxBytes = 64 * 1024

    static let allowedKeys: Set<String> = [
        "background", "foreground", "palette",
        "cursor-color", "cursor-text",
        "selection-background", "selection-foreground",
        "bold-color",
        "split-divider-color", "unfocused-split-fill",
        "search-background", "search-foreground",
        "search-selected-background", "search-selected-foreground",
        "window-titlebar-background", "window-titlebar-foreground",
        "macos-icon-ghost-color", "macos-icon-screen-color",
    ]

    static func parse(json: [String: Any], root: URL) -> ThemeContribution? {
        guard let name = LanguageManifest.displayString(json["name"]), name.count <= 64 else {
            return nil
        }
        guard let fileURL = LanguageContribution.containedURL(json["path"], root: root),
              isColorOnlyThemeFile(at: fileURL)
        else { return nil }

        return ThemeContribution(
            name: name,
            fileURL: fileURL,
            appearance: LanguageManifest.string(json["appearance"]).flatMap(Appearance.init(rawValue:))
        )
    }

    static func isColorOnlyThemeFile(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= maxBytes,
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return false }
        return isColorOnly(contents)
    }

    static func isColorOnly(_ contents: String) -> Bool {
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { return false }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            guard allowedKeys.contains(key) else { return false }
        }
        return true
    }
}

struct IconThemeContribution: Equatable, Sendable {
    let name: String
    let directoryURL: URL

    static let maxIconThemes = 16

    static func parse(json: [String: Any], root: URL) -> IconThemeContribution? {
        guard let name = LanguageManifest.displayString(json["name"]), name.count <= 64 else {
            return nil
        }
        guard let directoryURL = LanguageContribution.containedURL(json["path"], root: root),
              (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { return nil }
        return IconThemeContribution(name: name, directoryURL: directoryURL)
    }
}
