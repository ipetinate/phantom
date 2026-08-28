import Foundation

/// Every tool the app offers, in the order a reader would meet them.
///
/// One list, assembled from the files that own each group. A tool is declared
/// beside the thing it operates on — the terminals with the terminals, the
/// editor with the editor — and this is the only place that knows about all
/// of them.
@MainActor
enum MCPToolRegistry {
    static var all: [MCPToolHandler] {
        MCPTerminalTools.all + MCPGroupTools.all + MCPEditorTools.all
            + MCPDiagnosticTools.all + MCPLanguageServerTools.all
            + MCPWorktreeTools.all
    }
}
