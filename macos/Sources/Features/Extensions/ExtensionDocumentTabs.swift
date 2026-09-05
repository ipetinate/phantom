import AppKit

@MainActor
enum ExtensionDocumentTabs {
    static func open(_ entry: ExtensionIndex.Entry) {
        open(ExtensionDocument(entry: entry))
    }

    static func open(installed: InstalledExtension) {
        open(ExtensionDocument(installed: installed))
    }

    static func open(_ document: ExtensionDocument) {
        guard let controller = TerminalController.preferredParent ?? newWindow() else { return }
        controller.openExtensionInEditor(document)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    static func openInSettings(id: String) {
        SettingsNavigation.shared.target = SettingsNavigation.Target(
            section: .extensions,
            row: SettingsNavigation.contributedRow(id)
        )
        _ = NSApp.sendAction(#selector(AppDelegate.openConfig(_:)), to: nil, from: nil)
    }

    private static func newWindow() -> TerminalController? {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return nil }
        return TerminalController.newWindow(ghostty)
    }
}
