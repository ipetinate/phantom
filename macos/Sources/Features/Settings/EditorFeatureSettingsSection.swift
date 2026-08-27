import SwiftUI

/// The switches for what the editor does on its own, as a section of the
/// Editor pane.
///
/// One row per `EditorFeatureSettings.Key`, built from `allCases` rather
/// than from a list written out here. The store already holds the name of
/// each behaviour and the sentence under it, and a second copy in this file
/// would be a second thing to keep true: a seventh behaviour added there
/// arrives here with nothing to change.
///
/// Every row shows its own `detail` under the title rather than behind a
/// tooltip. A title says what a behaviour is, which is not the question
/// somebody in this pane is asking — they are asking what they lose by
/// turning it off, and that answer has to be readable without hovering to
/// find it.
struct EditorFeatureSettingsSection: View {
    /// Observed rather than read once: the store bumps `revision` on every
    /// write, so a switch moved here redraws without a `@State` of its own.
    @ObservedObject private var features = EditorFeatureSettings.shared

    /// The completion master, through the key "Suggest Completions" writes
    /// in the section below. Read here so the one row it governs follows it
    /// as it moves, rather than at the next time this pane is opened.
    @AppStorage(CompletionSettingsStore.enabledKey) private var completionEnabled = true

    var body: some View {
        Section {
            ForEach(EditorFeatureSettings.Key.allCases, id: \.rawValue) { key in
                Toggle(isOn: binding(for: key)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: key.title)

                        Text(verbatim: key.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            /// Wraps rather than truncates. A detail cut off
                            /// at the switch is a detail nobody can read,
                            /// which is the tooltip problem again with extra
                            /// steps.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .disabled(isAlreadyAnswered(key))
            }
        } header: {
            Text("Assistance")
        } footer: {
            Text("""
            Each of these is something the editor does for you without being \
            asked, and each one starts on. Turning one off never reaches \
            what you invoke yourself — a rename, a format, an explicit \
            request — because you already chose those.

            Suggest Completions, under Completion below, is the master for \
            suggestions: with it off nothing completes at all, whatever is \
            set here.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Whether a master switch has already answered this row.
    ///
    /// One key has one, and the exception is cheaper than what it prevents.
    /// `completionWhileTyping` decides whether the list arrives unasked; with
    /// Suggest Completions off no list arrives at all, asked or not, so the
    /// row has nothing left to decide. A live switch that changes nothing is
    /// worse than a named case in a loop, and the loop still carries a
    /// seventh behaviour in for free.
    private func isAlreadyAnswered(_ key: EditorFeatureSettings.Key) -> Bool {
        key == .completionWhileTyping && !completionEnabled
    }

    private func binding(for key: EditorFeatureSettings.Key) -> Binding<Bool> {
        Binding(
            get: { features.isEnabled(key) },
            set: { features.set(key, to: $0) }
        )
    }
}
