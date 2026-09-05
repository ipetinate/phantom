import AppKit

@MainActor
enum ExtensionTabOpener {
    static func open(_ document: ExtensionDocument) {
        guard let controller = TerminalController.preferredParent ?? newWindow() else { return }
        controller.openExtensionInEditor(document)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    static func open(_ entry: ExtensionIndex.Entry) {
        open(ExtensionDocument(entry: entry))
    }

    static func open(installed: InstalledExtension) {
        open(ExtensionDocument(installed: installed))
    }

    private static func newWindow() -> TerminalController? {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return nil }
        return TerminalController.newWindow(ghostty)
    }
}
