import SwiftUI
import WebKit

struct HTMLDocumentWebView: NSViewRepresentable {
    let documentURL: URL
    let vaultURL: URL
    let onInternalNavigation: (String) -> Void
    let onExternalNavigation: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            documentURL: documentURL,
            vaultURL: vaultURL,
            onInternalNavigation: onInternalNavigation,
            onExternalNavigation: onExternalNavigation
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
            onInternalNavigation: onInternalNavigation,
            onExternalNavigation: onExternalNavigation
        )
        context.coordinator.load(documentURL: documentURL, vaultURL: vaultURL, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var documentURL: URL
        private var vaultURL: URL
        private var onInternalNavigation: (String) -> Void
        private var onExternalNavigation: (URL) -> Void
        private var loadedDocumentURL: URL?

        init(
            documentURL: URL,
            vaultURL: URL,
            onInternalNavigation: @escaping (String) -> Void,
            onExternalNavigation: @escaping (URL) -> Void
        ) {
            self.documentURL = documentURL
            self.vaultURL = vaultURL
            self.onInternalNavigation = onInternalNavigation
            self.onExternalNavigation = onExternalNavigation
        }

        func update(
            documentURL: URL,
            vaultURL: URL,
            onInternalNavigation: @escaping (String) -> Void,
            onExternalNavigation: @escaping (URL) -> Void
        ) {
            self.documentURL = documentURL
            self.vaultURL = vaultURL
            self.onInternalNavigation = onInternalNavigation
            self.onExternalNavigation = onExternalNavigation
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
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if url.isFileURL, let relativePath = vaultRelativePath(for: url, in: vaultURL) {
                decisionHandler(.cancel)
                onInternalNavigation(relativePath)
                return
            }

            decisionHandler(.cancel)
            onExternalNavigation(url)
        }

        private func vaultRelativePath(for fileURL: URL, in vaultURL: URL) -> String? {
            let fileComponents = fileURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let vaultComponents = vaultURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents

            guard fileComponents.count > vaultComponents.count else { return nil }
            guard zip(vaultComponents, fileComponents).allSatisfy({ $0 == $1 }) else { return nil }

            return fileComponents
                .dropFirst(vaultComponents.count)
                .joined(separator: "/")
        }
    }
}
