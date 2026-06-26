import SwiftUI
import HTMLGraphCore
import WebKit

enum WebResourcePolicy {
    /// WKContentRuleList's `url-filter` uses a restricted regex subset that does
    /// NOT support alternation — `^(https?|wss?|ftp)://` fails to compile with
    /// "Disjunctions are not supported yet", which aborts the whole page load.
    /// Express each network scheme as its own rule using only the supported `?`
    /// quantifier and `^` anchor.
    static let networkBlockURLFilters = [
        "^https?://",
        "^wss?://",
        "^ftp://"
    ]

    /// Content-rule-list JSON that blocks every network scheme EXCEPT the app's own
    /// loopback origin, which is re-allowed via `ignore-previous-rules`. Documents now
    /// render from `http://127.0.0.1:<port>/`, so without this exception the block
    /// rules would also kill the page's own vault assets while offline.
    static func networkBlockRuleJSON(allowingLoopbackPort port: UInt16) -> String {
        let blocks = networkBlockURLFilters
            .map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
        // http only: the loopback server never serves TLS, so don't widen the
        // exception to https on the same port.
        let allowLoopback =
            #"{"trigger":{"url-filter":"^http://127\\.0\\.0\\.1:\#(port)/"},"action":{"type":"ignore-previous-rules"}}"#
        return "[\((blocks + [allowLoopback]).joined(separator: ","))]"
    }
}

struct HTMLDocumentWebView: NSViewRepresentable {
    let documentURL: URL
    let vaultURL: URL
    /// Loopback server origin (`http://127.0.0.1:<port>/<token>/`) the document is served from.
    let baseURL: URL
    let policy: VaultSecurityPolicy
    let knownDocumentIds: Set<String>
    let onInternalNavigation: (String) -> Void
    let onExternalNavigation: (URL) -> Void
    let onNavigationError: (String) -> Void
    let onNetworkBlocked: (URL) -> Void
    let pdfExportBridge: PDFExportBridge?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            documentURL: documentURL,
            vaultURL: vaultURL,
            baseURL: baseURL,
            policy: policy,
            knownDocumentIds: knownDocumentIds,
            onInternalNavigation: onInternalNavigation,
            onExternalNavigation: onExternalNavigation,
            onNavigationError: onNavigationError,
            onNetworkBlocked: onNetworkBlocked,
            pdfExportBridge: pdfExportBridge
        )
    }

    // The WKWebView lives inside a plain container NSView and is sized with an
    // AUTORESIZING MASK, not Auto Layout constraints. WebKit's macOS media/fullscreen
    // machinery saves and restores the web view's superview constraints when an
    // HTML5 <video> lays out; activated constraints here collide with that and
    // corrupt the host window's titlebar/safe-area (the sidebar then draws up under
    // the traffic-light buttons). Autoresizing within our own container sidesteps it.
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizesSubviews = true

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = policy.allowsJavaScript

        let webView = WKWebView(frame: container.bounds, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = context.coordinator
        container.addSubview(webView)

        context.coordinator.webView = webView
        context.coordinator.registerPDFExport(from: webView)
        context.coordinator.prepareContentRulesIfNeeded(in: webView) {
            context.coordinator.load(in: webView)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let webView = context.coordinator.webView else { return }
        context.coordinator.update(
            documentURL: documentURL,
            vaultURL: vaultURL,
            baseURL: baseURL,
            policy: policy,
            knownDocumentIds: knownDocumentIds,
            onInternalNavigation: onInternalNavigation,
            onExternalNavigation: onExternalNavigation,
            onNavigationError: onNavigationError,
            onNetworkBlocked: onNetworkBlocked,
            pdfExportBridge: pdfExportBridge
        )
        context.coordinator.registerPDFExport(from: webView)
        context.coordinator.prepareContentRulesIfNeeded(in: webView) {
            context.coordinator.load(in: webView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.unregisterPDFExport()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var documentURL: URL
        private var vaultURL: URL
        private var baseURL: URL
        private var policy: VaultSecurityPolicy
        private var knownDocumentIds: Set<String>
        private var onInternalNavigation: (String) -> Void
        private var onExternalNavigation: (URL) -> Void
        private var onNavigationError: (String) -> Void
        private var onNetworkBlocked: (URL) -> Void
        private var pdfExportBridge: PDFExportBridge?
        private let pdfRegistrationID = UUID()
        private var loadedDocumentURL: URL?
        private var contentRulesInstalled = false
        weak var webView: WKWebView?

        init(
            documentURL: URL,
            vaultURL: URL,
            baseURL: URL,
            policy: VaultSecurityPolicy,
            knownDocumentIds: Set<String>,
            onInternalNavigation: @escaping (String) -> Void,
            onExternalNavigation: @escaping (URL) -> Void,
            onNavigationError: @escaping (String) -> Void,
            onNetworkBlocked: @escaping (URL) -> Void,
            pdfExportBridge: PDFExportBridge?
        ) {
            self.documentURL = documentURL
            self.vaultURL = vaultURL
            self.baseURL = baseURL
            self.policy = policy
            self.knownDocumentIds = knownDocumentIds
            self.onInternalNavigation = onInternalNavigation
            self.onExternalNavigation = onExternalNavigation
            self.onNavigationError = onNavigationError
            self.onNetworkBlocked = onNetworkBlocked
            self.pdfExportBridge = pdfExportBridge
        }

        func update(
            documentURL: URL,
            vaultURL: URL,
            baseURL: URL,
            policy: VaultSecurityPolicy,
            knownDocumentIds: Set<String>,
            onInternalNavigation: @escaping (String) -> Void,
            onExternalNavigation: @escaping (URL) -> Void,
            onNavigationError: @escaping (String) -> Void,
            onNetworkBlocked: @escaping (URL) -> Void,
            pdfExportBridge: PDFExportBridge?
        ) {
            self.documentURL = documentURL
            self.vaultURL = vaultURL
            self.baseURL = baseURL
            self.policy = policy
            self.knownDocumentIds = knownDocumentIds
            self.onInternalNavigation = onInternalNavigation
            self.onExternalNavigation = onExternalNavigation
            self.onNavigationError = onNavigationError
            self.onNetworkBlocked = onNetworkBlocked
            self.pdfExportBridge = pdfExportBridge
        }

        func registerPDFExport(from webView: WKWebView) {
            pdfExportBridge?.register(id: pdfRegistrationID) { [weak webView] in
                guard let webView else { throw DocumentPDFExportError.rendererUnavailable }
                return try await DocumentPDFExporter.pdfData(from: webView)
            }
        }

        func unregisterPDFExport() {
            pdfExportBridge?.unregister(id: pdfRegistrationID)
        }

        func prepareContentRulesIfNeeded(in webView: WKWebView, completion: @escaping () -> Void) {
            guard !policy.allowsNetworkAccess else {
                completion()
                return
            }

            guard !contentRulesInstalled else {
                completion()
                return
            }

            guard let port = baseURL.port.map({ UInt16(truncatingIfNeeded: $0) }) else {
                onNavigationError("Could not determine the local preview port.")
                return
            }

            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "HTMLGraphBlockNetwork-\(port)",
                encodedContentRuleList: WebResourcePolicy.networkBlockRuleJSON(allowingLoopbackPort: port)
            ) { [weak self, weak webView] ruleList, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let ruleList, let webView {
                        webView.configuration.userContentController.add(ruleList)
                        self.contentRulesInstalled = true
                        completion()
                    } else {
                        self.onNavigationError(error?.localizedDescription ?? "Could not install network blocking rules.")
                    }
                }
            }
        }

        func load(in webView: WKWebView) {
            let standardizedDocumentURL = documentURL.standardizedFileURL
            guard loadedDocumentURL != standardizedDocumentURL else { return }

            guard policy.allows(standardizedDocumentURL, vaultRoot: vaultURL),
                  let resourceURL = VaultHTTPServer.resourceURL(
                      forFileAt: standardizedDocumentURL,
                      baseURL: baseURL,
                      vaultURL: vaultURL
                  ) else {
                onNavigationError("Cannot load document outside the selected vault.")
                return
            }

            loadedDocumentURL = standardizedDocumentURL
            webView.load(URLRequest(url: resourceURL))
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

            // Loopback URLs are our own vault content; map them back to the file they
            // serve so the (file-based) navigation policy can classify them. Everything
            // else (about:blank, external https, an embedded YouTube frame) is judged
            // by its real URL.
            let targetURL = VaultHTTPServer.fileURL(forLoopback: url, baseURL: baseURL, vaultURL: vaultURL) ?? url

            let navigationPolicy = HTMLDocumentNavigationPolicy(
                currentDocumentURL: documentURL,
                vaultURL: vaultURL,
                knownDocumentIds: knownDocumentIds,
                allowsNetworkAccess: policy.allowsNetworkAccess
            )
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

            switch navigationPolicy.decision(
                for: targetURL,
                isMainFrame: isMainFrame,
                isUserInitiated: navigationAction.navigationType == .linkActivated
            ) {
            case .allow:
                decisionHandler(.allow)
            case .internalDocument(let relativePath):
                decisionHandler(.cancel)
                onInternalNavigation(relativePath)
            case .external(let externalURL):
                decisionHandler(.cancel)
                onExternalNavigation(externalURL)
            case .networkBlocked(let blockedURL):
                decisionHandler(.cancel)
                onNetworkBlocked(blockedURL)
            case .error(let message):
                decisionHandler(.cancel)
                onNavigationError(message)
            }
        }
    }
}
