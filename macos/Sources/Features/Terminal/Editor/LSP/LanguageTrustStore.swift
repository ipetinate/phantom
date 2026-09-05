import Foundation

/// Reads and writes trust decisions, keyed by extension id.
///
/// In `UserDefaults` and not in the config directory, which is the one
/// design decision in this file: `~/.config/phantom/extensions/<id>/` is
/// writable by whatever put the manifest there, and a record kept beside
/// the thing it judges is a record that thing can forge.
///
/// Keyed by **id**, with the digest inside the record rather than in the
/// key. That is what makes a refusal stick: a store keyed by `id + digest`
/// would let an author get a fresh prompt by reformatting the file, and an
/// author who can re-prompt at will eventually catches somebody in a hurry.
/// An *approval* is still only good for the digest it names —
/// `LanguageTrust.verdict(for:record:)` compares them.
///
/// Sibling to `LSPServerOverrideStore`, and the split between them is
/// deliberate: an override is keyed by the **default command**, because
/// "point this at a different binary" is a fact about a binary that four
/// language ids share. Trust is keyed by the **extension id**, because
/// "I approved this publisher's code" is a fact about the extension. Do not
/// merge them; the keys mean different things and one of them is a security
/// boundary.
enum LanguageTrustStore {
    static let defaultsKey = "LanguageExtensionTrust"

    /// Bumped when `LanguageTrustRecord` changes shape in a way that alters
    /// what an approval covers.
    static let currentRecordVersion = 1

    static var all: [String: LanguageTrustRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(
                  [String: LanguageTrustRecord].self,
                  from: data
              )
        else { return [:] }
        return decoded
    }

    /// The decision for an extension, or nil when there is none this build
    /// can read.
    ///
    /// A record from a future version reads as **absent**, which means the
    /// user is asked again. Absent never means allowed.
    static func record(for extensionID: String) -> LanguageTrustRecord? {
        guard let record = all[extensionID] else { return nil }
        guard record.recordVersion <= currentRecordVersion else { return nil }
        return record
    }

    static func set(_ record: LanguageTrustRecord, for extensionID: String) {
        guard !extensionID.isEmpty else { return }
        var current = all
        current[extensionID] = record
        guard let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Drops a decision, which is the only way back from a refusal — and it
    /// is reachable only from Settings, never from an extension and never
    /// from the prompt itself.
    static func forget(_ extensionID: String) {
        var current = all
        guard current.removeValue(forKey: extensionID) != nil else { return }
        guard let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Records an answer to a prompt.
    static func remember(
        _ decision: LanguageTrustRecord.Decision,
        for subject: LanguageTrust.Subject
    ) {
        guard case .manifest(let provenance) = subject.origin else { return }
        set(
            LanguageTrust.record(
                for: subject,
                decision: decision,
                extending: record(for: provenance.extensionID)
            ),
            for: provenance.extensionID
        )
    }
}

/// Which contributed languages the user has chosen to put ahead of the
/// compiled-in ones.
///
/// Precedence is **compiled registry > user extension > bundled extension**,
/// and it is not negotiable by a file: copying an extension in must never
/// change a language the user already had. A contribution that claims a file
/// type this build already owns loads *conflicted* — parsed, listed,
/// inert — and a button in Settings promotes it. The power exists; the
/// gesture is the user's.
///
/// Persisted in the same idiom as `LanguageTrustStore`, and in
/// `UserDefaults` for the same reason: a precedence decision stored in the
/// config directory is a precedence decision the manifest's author can
/// grant itself.
enum LanguagePromotionStore {
    static let defaultsKey = "LanguageExtensionPromotions"

    /// One promotion covers one language of one extension, so promoting an
    /// Elixir contribution does not also promote whatever else the same
    /// extension happened to claim.
    static func key(extensionID: String, languageID: String) -> String {
        extensionID + "#" + languageID
    }

    static var all: Set<String> {
        guard let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [String]
        else { return [] }
        return Set(stored)
    }

    static func isPromoted(extensionID: String, languageID: String) -> Bool {
        all.contains(key(extensionID: extensionID, languageID: languageID))
    }

    static func setPromoted(
        _ promoted: Bool,
        extensionID: String,
        languageID: String
    ) {
        guard !extensionID.isEmpty, !languageID.isEmpty else { return }
        var current = all
        let entry = key(extensionID: extensionID, languageID: languageID)
        if promoted {
            current.insert(entry)
        } else {
            current.remove(entry)
        }
        UserDefaults.standard.set(current.sorted(), forKey: defaultsKey)
    }
}
