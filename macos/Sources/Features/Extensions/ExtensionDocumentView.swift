import AppKit
import SwiftUI
import WebKit

struct ExtensionDocumentView: NSViewRepresentable {
    enum Status: Equatable {
        case rendering
        case rendered(warnings: [String])
        case failed(message: String, line: Int?, column: Int?)
    }

    struct Request: Equatable {
        let viewerHTML: URL
        let document: URL
        let base: URL
        let cover: String?
    }

    let request: Request
    let theme: [String: Any]
    let onStatus: (Status) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStatus: onStatus)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.userContentController.add(context.coordinator, name: Coordinator.handlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

        context.coordinator.webView = webView
        context.coordinator.load(request, theme: theme)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onStatus = onStatus
        context.coordinator.update(request, theme: theme)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.handlerName)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.webView = nil
    }

    static func renderPayload(_ request: Request, themeJSON: String) -> String? {
        guard let data = try? Data(contentsOf: request.document),
              data.count <= ExtensionMediaGate.maxDocumentBytes,
              let source = String(data: data, encoding: .utf8)
        else { return nil }

        let object: [String: Any] = [
            "source": source,
            "baseURL": request.document.deletingLastPathComponent().absoluteString,
            "cover": request.cover ?? NSNull(),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: json, encoding: .utf8),
              text.hasSuffix("}")
        else { return nil }
        return String(text.dropLast()) + ",\"theme\":" + themeJSON + "}"
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let handlerName = "phantom"

        var onStatus: (Status) -> Void
        weak var webView: WKWebView?

        private var loaded: Request?
        private var pending: Request?
        private var shown: Request?
        private var isReady = false
        private var themeJSON = "{}"

        init(onStatus: @escaping (Status) -> Void) {
            self.onStatus = onStatus
        }

        func load(_ request: Request, theme: [String: Any]) {
            themeJSON = ExtensionViewerTheme.json(theme)
            loaded = request
            pending = request
            shown = nil
            isReady = false
            onStatus(.rendering)
            webView?.loadFileURL(request.viewerHTML, allowingReadAccessTo: request.base)
        }

        func update(_ request: Request, theme: [String: Any]) {
            guard let loaded, loaded.viewerHTML == request.viewerHTML, loaded.base == request.base else {
                load(request, theme: theme)
                return
            }

            let json = ExtensionViewerTheme.json(theme)
            if json != themeJSON {
                themeJSON = json
                if isReady { evaluate("window.phantomViewer.setTheme(\(json))") }
            }

            guard request != shown, request != pending else { return }
            pending = request
            flush()
        }

        private func flush() {
            guard isReady, let request = pending else { return }
            pending = nil
            shown = request
            onStatus(.rendering)

            guard let payload = ExtensionDocumentView.renderPayload(request, themeJSON: themeJSON) else {
                onStatus(.failed(message: "The document could not be read.", line: nil, column: nil))
                return
            }
            evaluate("window.phantomViewer.render(\(payload))")
        }

        private func evaluate(_ script: String) {
            webView?.evaluateJavaScript(script) { _, _ in }
        }

        func handle(_ message: ExtensionViewerMessage) {
            switch message {
            case .ready:
                isReady = true
                flush()
            case .rendered(let warnings):
                onStatus(.rendered(warnings: warnings))
            case .failed(let message, let line, let column):
                onStatus(.failed(message: message, line: line, column: column))
            case .open(let url):
                NSWorkspace.shared.open(url)
            case .copy(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let parsed = ExtensionViewerMessage.parse(message.body) else { return }
            handle(parsed)
        }

        // MARK: WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            if navigationAction.navigationType == .linkActivated {
                if let target = ExtensionViewerMessage.openableURL(url?.absoluteString) {
                    NSWorkspace.shared.open(target)
                }
                decisionHandler(.cancel)
                return
            }

            guard navigationAction.targetFrame?.isMainFrame == true,
                  let url,
                  let loaded,
                  url.standardizedFileURL == loaded.viewerHTML.standardizedFileURL
            else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // MARK: WKUIDelegate

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}
