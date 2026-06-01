import SwiftUI
import HTMLGraphCore
import WebKit

enum WebResourcePolicy {
    static let networkBlockURLFilter = "^(https?|wss?|ftp)://"

    static let networkBlockRuleJSON = """
    [{
      "trigger": {
        "url-filter": "\(networkBlockURLFilter)"
      },
      "action": {
        "type": "block"
      }
    }]
    """
}

struct HTMLDocumentWebView: NSViewRepresentable {
    let documentURL: URL
    let vaultURL: URL
    let policy: VaultSecurityPolicy
    let knownDocumentIds: Set<String>
    let onInternalNavigation: (String) -> Void
    let onExternalNavigation: (URL) -> Void
    let onNavigationError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            documentURL: documentURL,
            vaultURL: vaultURL,
            policy: policy,
            knownDocumentIds: knownDocumentIds,
            onInternalNavigation: onInternalNavigation,
            onExternalNavigation: onExternalNavigation,
            onNavigationError: onNavigationError
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            VaultResourceSchemeHandler(vaultURL: vaultURL, policy: policy),
            forURLScheme: "htmlgraph"
        )
        configuration.defaultWebpagePreferences.allowsContentJavaScript = policy.allowsJavaScript

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.prepareContentRulesIfNeeded(in: webView) {
            context.coordinator.load(documentURL: documentURL, vaultURL: vaultURL, policy: policy, in: webView)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            documentURL: documentURL,
            vaultURL: vaultURL,
            policy: policy,
            knownDocumentIds: knownDocumentIds,
            onInternalNavigation: onInternalNavigation,
            onExternalNavigation: onExternalNavigation,
            onNavigationError: onNavigationError
        )
        context.coordinator.prepareContentRulesIfNeeded(in: webView) {
            context.coordinator.load(documentURL: documentURL, vaultURL: vaultURL, policy: policy, in: webView)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var documentURL: URL
        private var vaultURL: URL
        private var policy: VaultSecurityPolicy
        private var knownDocumentIds: Set<String>
        private var onInternalNavigation: (String) -> Void
        private var onExternalNavigation: (URL) -> Void
        private var onNavigationError: (String) -> Void
        private var loadedDocumentURL: URL?
        private var contentRulesInstalled = false

        init(
            documentURL: URL,
            vaultURL: URL,
            policy: VaultSecurityPolicy,
            knownDocumentIds: Set<String>,
            onInternalNavigation: @escaping (String) -> Void,
            onExternalNavigation: @escaping (URL) -> Void,
            onNavigationError: @escaping (String) -> Void
        ) {
            self.documentURL = documentURL
            self.vaultURL = vaultURL
            self.policy = policy
            self.knownDocumentIds = knownDocumentIds
            self.onInternalNavigation = onInternalNavigation
            self.onExternalNavigation = onExternalNavigation
            self.onNavigationError = onNavigationError
        }

        func update(
            documentURL: URL,
            vaultURL: URL,
            policy: VaultSecurityPolicy,
            knownDocumentIds: Set<String>,
            onInternalNavigation: @escaping (String) -> Void,
            onExternalNavigation: @escaping (URL) -> Void,
            onNavigationError: @escaping (String) -> Void
        ) {
            self.documentURL = documentURL
            self.vaultURL = vaultURL
            self.policy = policy
            self.knownDocumentIds = knownDocumentIds
            self.onInternalNavigation = onInternalNavigation
            self.onExternalNavigation = onExternalNavigation
            self.onNavigationError = onNavigationError
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

            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "HTMLGraphBlockNetwork",
                encodedContentRuleList: WebResourcePolicy.networkBlockRuleJSON
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

        func load(documentURL: URL, vaultURL: URL, policy: VaultSecurityPolicy, in webView: WKWebView) {
            let standardizedDocumentURL = documentURL.standardizedFileURL
            guard loadedDocumentURL != standardizedDocumentURL else { return }

            guard policy.allows(standardizedDocumentURL, vaultRoot: vaultURL),
                  let resourceURL = VaultResourceSchemeHandler.vaultURL(
                      for: standardizedDocumentURL,
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

            let targetURL: URL
            if url.scheme?.lowercased() == "htmlgraph" {
                guard let fileURL = VaultResourceSchemeHandler.fileURL(
                    for: url,
                    vaultURL: vaultURL,
                    policy: policy
                ) else {
                    decisionHandler(.cancel)
                    onNavigationError("Blocked invalid vault navigation: \(url.absoluteString)")
                    return
                }
                targetURL = fileURL
            } else {
                targetURL = url
            }

            let navigationPolicy = HTMLDocumentNavigationPolicy(
                currentDocumentURL: documentURL,
                vaultURL: vaultURL,
                knownDocumentIds: knownDocumentIds
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
            case .error(let message):
                decisionHandler(.cancel)
                onNavigationError(message)
            }
        }
    }
}
