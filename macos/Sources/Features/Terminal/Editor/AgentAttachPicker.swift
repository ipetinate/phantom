import AppKit
import SwiftUI

/// What ⇧⌘K is asking to attach: the file and the lines, held while the
/// picker is on screen. The reference string is built per target, because
/// "relative to the terminal's cwd" depends on which terminal wins.
struct AgentAttachRequest: Identifiable {
    let id = UUID()
    let filePath: String
    let lines: (start: Int, end: Int)

    func reference(cwd: String?) -> String {
        EditorLineReference.reference(filePath: filePath, lines: lines, cwd: cwd)
    }
}

/// The sheet asking which terminal receives the reference.
///
/// A sheet in the editor rather than the command palette, because the palette
/// is an overlay on the terminal container — which is hidden exactly while
/// the editor is on screen.
struct AgentAttachPicker: View {
    let request: AgentAttachRequest
    let onDone: () -> Void

    @State private var targets: [AgentAttach.Target] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Attach to which terminal?")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if targets.isEmpty {
                Text("No terminals are open.")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(targets) { target in
                            row(target)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 320)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 380)
        .onAppear { targets = AgentAttach.targets() }
    }

    private func row(_ target: AgentAttach.Target) -> some View {
        Button {
            AgentAttach.send({ request.reference(cwd: $0) }, to: target)
            onDone()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: target.agentName == nil ? "terminal" : "sparkle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(target.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        if let agent = target.agentName {
                            Text(agent)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        }
                    }
                    if let pwd = target.pwd {
                        Text(pwd.abbreviatedPath)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.0001)))
    }
}
