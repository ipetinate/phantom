import Foundation

/// One formatter's worth of the reader's own decisions.
///
/// Both text fields read as "no change" when blank rather than as the
/// registry's own values, so somebody pointing `ruff` at a different binary
/// does not also have to retype the arguments they were happy with. The same
/// shape, and the same reason, as `LSPServerOverride`.
struct ExternalFormatterSetting: Codable, Equatable {
    var command: String = ""
    var arguments: String = ""
    var isEnabled: Bool = true

    var isDefault: Bool {
        isEnabled
            && command.trimmingCharacters(in: .whitespaces).isEmpty
            && arguments.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Reads and writes the per-formatter settings, keyed by the registry's id.
///
/// Keyed by id and not by command, which is the opposite of
/// `LSPServerOverrideStore` and for the opposite reason: there, four language
/// ids share one server process, so the *command* is the identity. Here every
/// formatter is one language and one tool, and the command is the thing being
/// edited — an identity that changes when the setting changes is no identity.
///
/// `ExternalFormatterRegistry` stays pure data with no `UserDefaults` in it.
/// This is the layer above where a reader's choices live, and `effective`
/// is where the two meet.
enum ExternalFormatterStore {
    static let defaultsKey = "ExternalFormatters"

    static var all: [String: ExternalFormatterSetting] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(
                [String: ExternalFormatterSetting].self, from: data)
        else { return [:] }
        return decoded
    }

    static func setting(for id: String) -> ExternalFormatterSetting {
        all[id] ?? ExternalFormatterSetting()
    }

    static func set(_ setting: ExternalFormatterSetting, for id: String) {
        var current = all
        if setting.isDefault {
            current.removeValue(forKey: id)
        } else {
            current[id] = setting
        }
        guard let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// The formatter as it will actually run, or nil when the reader has
    /// switched it off.
    ///
    /// Blank overrides fall through to the registry one field at a time, which
    /// is what makes "just point it somewhere else" a one-field edit.
    static func effective(_ formatter: ExternalFormatter) -> ExternalFormatter? {
        effective(formatter, setting: setting(for: formatter.id))
    }

    /// The merge on its own, so it can be exercised without `UserDefaults`.
    static func effective(
        _ formatter: ExternalFormatter,
        setting: ExternalFormatterSetting
    ) -> ExternalFormatter? {
        guard setting.isEnabled else { return nil }

        let command = setting.command.trimmingCharacters(in: .whitespaces)
        let arguments = setting.arguments.trimmingCharacters(in: .whitespaces)

        return ExternalFormatter(
            id: formatter.id,
            languageName: formatter.languageName,
            displayName: formatter.displayName,
            command: command.isEmpty ? formatter.command : command,
            arguments: arguments.isEmpty ? formatter.arguments : Self.split(arguments),
            extensions: formatter.extensions,
            installHint: formatter.installHint,
            note: formatter.note,
            provenance: formatter.provenance)
    }

    /// A typed argument line, split the way a shell would split the simple
    /// case and no further.
    ///
    /// No quoting, no escapes. Every argument these tools take is a flag or a
    /// placeholder, and a half-implemented shell parser — one that handles
    /// `"a b"` but not `a\ b`, or the other way round — is worse than one that
    /// plainly does not try.
    static func split(_ arguments: String) -> [String] {
        arguments.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
