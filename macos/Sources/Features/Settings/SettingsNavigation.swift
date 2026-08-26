import Combine
import Foundation

/// A request to open Settings at one place in it.
///
/// The settings window keeps a single hosting view alive across opens, so
/// the starting selection cannot travel as an argument: by the second open
/// the view that would read it already exists. Both halves watch this
/// instead — ``SettingsRootView`` for the section, and the section's own
/// view for the row inside it.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()

    /// Where to land. `row` is the id of a row in that section's list, nil
    /// for a section with no list or a caller with nothing more specific to
    /// say than the pane.
    struct Target: Equatable {
        let section: SettingsRootView.SettingsSection
        let row: String?

        /// One request, distinct from the next. Without it a second click
        /// on the same button would publish an equal value and change
        /// nothing, so a reader who had navigated away could not get back.
        let id = UUID()
    }

    /// Set by whoever wants the window somewhere specific, cleared by the
    /// view that lands on it.
    @Published var target: Target?

    private init() {}

    /// The Languages pane's row for a server definition, or nil when
    /// nothing in that list stands for it.
    ///
    /// The caller holds neither id, and there are two kinds. A compiled-in
    /// server is listed under the command the registry names, which a user
    /// override may have repointed away from the one that actually ran — so
    /// the match is made on the effective command and the base command is
    /// what comes back. A contributed language is listed under its
    /// extension identity instead.
    static func languageRow(for definition: LSPServerDefinition) -> String? {
        if case .manifest(let provenance) = definition.origin {
            let contributed = LanguageResolver.shared.catalog.contributed.first {
                $0.provenance == provenance && $0.language.languageID == definition.languageID
            }
            return contributed.map { contributedRow($0.id) }
        }

        let base = LSPServerRegistry.distinctServers.first {
            LSPCenter.effectiveDefinition($0).command == definition.command
        } ?? LSPServerRegistry.server(forLanguage: definition.languageID)
        return base.map { serverRow($0.command) }
    }

    /// How ``LanguageServersSettingsView`` spells its row ids. Here so the
    /// caller naming a row and the list drawing it read one definition
    /// rather than two that agree today.
    ///
    /// `nonisolated` because the list's own row type is a plain value that
    /// asks for its id outside any actor.
    nonisolated static func serverRow(_ command: String) -> String { "server:" + command }

    nonisolated static func contributedRow(_ id: String) -> String { "ext:" + id }
}
