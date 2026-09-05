import AppKit
import SwiftUI

struct ConfirmationPrompt: Equatable {
    struct Detail: Equatable {
        let label: String
        let value: String
    }

    struct Action: Equatable {
        let title: String
        var isDefault = false
        var isDestructive = false
    }

    var title: String
    var consequence: String
    var change: String?
    var details: [Detail] = []
    var log: [String] = []
    var primary: Action
    var secondary: Action
    var remember: String?

    var detailText: String {
        details.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }
}

extension ConfirmationPrompt {
    @MainActor
    static func present(_ prompt: ConfirmationPrompt, on window: NSWindow?) async -> Bool {
        await withCheckedContinuation { continuation in
            present(prompt, on: window) { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    static func present(
        _ prompt: ConfirmationPrompt,
        on window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        let controller = NSHostingController(
            rootView: ConfirmationPromptView(prompt: prompt, respond: { _ in })
        )
        let panel = NSWindow(contentViewController: controller)
        panel.styleMask = [.titled, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        controller.rootView = ConfirmationPromptView(prompt: prompt) { chosePrimary in
            let response: NSApplication.ModalResponse = chosePrimary ? .OK : .cancel
            if let window, window.attachedSheet === panel {
                window.endSheet(panel, returnCode: response)
            } else {
                NSApp.stopModal(withCode: response)
            }
        }
        panel.setContentSize(controller.view.fittingSize)

        if let window {
            window.beginSheet(panel) { response in
                panel.orderOut(nil)
                completion(response == .OK)
            }
        } else {
            let response = NSApp.runModal(for: panel)
            panel.orderOut(nil)
            completion(response == .OK)
        }
    }
}

struct ConfirmationPromptView: View {
    let prompt: ConfirmationPrompt
    let respond: (Bool) -> Void

    @State private var detailsShown = false

    private static let width: CGFloat = 480
    private static let logHeight: CGFloat = 140

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSImage(named: NSImage.cautionName) ?? NSImage())
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 10) {
                Text(prompt.title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(prompt.consequence)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let change = prompt.change {
                    Text(change)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !prompt.details.isEmpty {
                    details
                }

                if !prompt.log.isEmpty {
                    log
                }

                if let remember = prompt.remember {
                    Text(remember)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    button(prompt.secondary, chosen: false)
                    button(prompt.primary, chosen: true)
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(width: Self.width)
    }

    private var details: some View {
        DisclosureGroup("Details", isExpanded: $detailsShown) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(prompt.details, id: \.label) { detail in
                    LabeledContent(detail.label) {
                        Text(verbatim: detail.value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)

                HStack {
                    Spacer(minLength: 0)
                    CopyButton(text: prompt.detailText, label: "Copy details")
                }
            }
            .padding(.top, 6)
        }
        .font(.system(size: 11))
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
                CopyButton(text: prompt.log.joined(separator: "\n"), label: "Copy log")
            }
            ScrollView {
                Text(verbatim: prompt.log.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: Self.logHeight)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func button(_ action: ConfirmationPrompt.Action, chosen: Bool) -> some View {
        Button(action.title, role: action.isDestructive ? .destructive : nil) {
            respond(chosen)
        }
        .keyboardShortcut(shortcut(for: action))
    }

    private func shortcut(for action: ConfirmationPrompt.Action) -> KeyboardShortcut? {
        if action.isDefault { return .defaultAction }
        if prompt.primary.isDefault != prompt.secondary.isDefault { return .cancelAction }
        return nil
    }
}
