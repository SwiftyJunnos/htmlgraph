import SwiftUI
import WebKit

struct HTMLDocumentWebView: NSViewRepresentable {
    let documentURL: URL
    let vaultURL: URL
    let knownDocumentIds: Set<String>
    let onInternalNavigation: (String) -> Void
    let onExternalNavigation: (URL) -> Void
    let onNavigationError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            documentURL: documentURL,
            vaultURL: vaultURL,
            knownDocumentIds: knownDocumentIds,
            onInternalNavigation: onInternalNavigation,
            onExternalNavigation: onExternalNavigation,
            onNavigationError: onNavigationError
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(documentURL: documentURL, vaultURL: vaultURL, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            documentURL: documentURL,
            vaultURL: vaultURL,
            knownDocumentIds: knownDocumentIds,
            onInternalNavigation: onInternalNavigation,
            onExternalNavigation: onExternalNavigation,
            onNavigationError: onNavigationError
        )
        context.coordinator.load(documentURL: documentURL, vaultURL: vaultURL, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var documentURL: URL
        private var vaultURL: URL
        private var knownDocumentIds: Set<String>
        private var onInternalNavigation: (String) -> Void
        private var onExternalNavigation: (URL) -> Void
        private var onNavigationError: (String) -> Void
        private var loadedDocumentURL: URL?

        init(
            documentURL: URL,
            vaultURL: URL,
            knownDocumentIds: Set<String>,
            onInternalNavigation: @escaping (String) -> Void,
            onExternalNavigation: @escaping (URL) -> Void,
            onNavigationError: @escaping (String) -> Void
        ) {
            self.documentURL = documentURL
            self.vaultURL = vaultURL
            self.knownDocumentIds = knownDocumentIds
            self.onInternalNavigation = onInternalNavigation
            self.onExternalNavigation = onExternalNavigation
            self.onNavigationError = onNavigationError
        }

        func update(
            documentURL: URL,
            vaultURL: URL,
            knownDocumentIds: Set<String>,
            onInternalNavigation: @escaping (String) -> Void,
            onExternalNavigation: @escaping (URL) -> Void,
            onNavigationError: @escaping (String) -> Void
        ) {
            self.documentURL = documentURL
            self.vaultURL = vaultURL
            self.knownDocumentIds = knownDocumentIds
            self.onInternalNavigation = onInternalNavigation
            self.onExternalNavigation = onExternalNavigation
            self.onNavigationError = onNavigationError
        }

        func load(documentURL: URL, vaultURL: URL, in webView: WKWebView) {
            let standardizedDocumentURL = documentURL.standardizedFileURL
            guard loadedDocumentURL != standardizedDocumentURL else { return }

            loadedDocumentURL = standardizedDocumentURL
            webView.loadFileURL(standardizedDocumentURL, allowingReadAccessTo: vaultURL.standardizedFileURL)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let policy = HTMLDocumentNavigationPolicy(
                currentDocumentURL: documentURL,
                vaultURL: vaultURL,
                knownDocumentIds: knownDocumentIds
            )
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

            switch policy.decision(for: url, isMainFrame: isMainFrame) {
            case .allow:
                decisionHandler(.allow)
            case .internalDocument(let relativePath):
                decisionHandler(.cancel)
                onInternalNavigation(relativePath)
            case .external(let externalURL):
                decisionHandler(.cancel)
                onExternalNavigation(externalURL)
            case .error(let message):
                decisionHandler(.cancel)
                onNavigationError(message)
            }
        }
    }
}
