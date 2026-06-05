import SwiftUI
import HTMLGraphCore
import WebKit

/// Lets the host pull the WYSIWYG editor's live DOM on demand (before a save or before
/// leaving the editor), so a synchronous save can't write a stale buffer. ReaderPane holds
/// one of these and hands it to `VisualHTMLEditor`, whose coordinator registers itself.
@MainActor
final class VisualEditorBridge {
    weak var coordinator: VisualHTMLEditor.Coordinator?
    /// Reads the freshest DOM snapshot and delivers it through the normal buffer-update path,
    /// awaiting completion so the caller can then save/leave knowing the buffer is current.
    func flush() async { await coordinator?.flush() }
}

/// In-place WYSIWYG editor: renders a document exactly like the reader, but makes its body
/// `contenteditable` so the user edits the rendered content directly instead of raw HTML.
///
/// Security stance — the document's *own* JavaScript stays disabled (`allowsContentJavaScript
/// = false`), so Safe mode is fully intact while editing. The editing affordance is injected
/// into an isolated `WKContentWorld`, which (verified empirically) still runs and can mutate
/// the shared DOM even with page JS off. The page is served from the same loopback origin as
/// the reader and the same network-blocking content rules apply.
///
/// As the user types, a debounced snapshot — the body inner-HTML, a full re-serialization,
/// and the document id — is posted via `onSnapshot`; the owner splices the body back into the
/// original source (preferred) or, if it can't, writes the full serialization (never lossy).
struct VisualHTMLEditor: NSViewRepresentable {
    let documentId: String
    let documentURL: URL
    let vaultURL: URL
    /// Loopback server origin (`http://127.0.0.1:<port>/<token>/`) the document is served from.
    let baseURL: URL
    let allowsNetworkAccess: Bool
    let bridge: VisualEditorBridge
    /// (documentId, body inner-HTML, full document serialization).
    let onSnapshot: (String, String, String?) -> Void
    let onNavigationError: (String) -> Void

    private static let editorWorldName = "HTMLGraphVisualEditor"
    private static let snapshotMessageName = "htmlgraphSnapshot"

    func makeCoordinator() -> Coordinator {
        Coordinator(
            documentId: documentId,
            baseURL: baseURL,
            vaultURL: vaultURL,
            allowsNetworkAccess: allowsNetworkAccess,
            world: WKContentWorld.world(name: Self.editorWorldName),
            onSnapshot: onSnapshot,
            onNavigationError: onNavigationError
        )
    }

    // Mirrors HTMLDocumentWebView: the web view sits in a plain container sized with an
    // autoresizing mask (not Auto Layout) to dodge WebKit's media/fullscreen constraint
    // juggling, which otherwise corrupts the host window's titlebar.
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizesSubviews = true

        let configuration = WKWebViewConfiguration()
        // The document's own scripts stay OFF; only our isolated-world editing script runs.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.editingScript(messageName: Self.snapshotMessageName, documentId: documentId),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: context.coordinator.world
            )
        )
        configuration.userContentController.add(
            context.coordinator, contentWorld: context.coordinator.world, name: Self.snapshotMessageName
        )

        let webView = WKWebView(frame: container.bounds, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = context.coordinator
        container.addSubview(webView)

        context.coordinator.webView = webView
        context.coordinator.bridge = bridge
        bridge.coordinator = context.coordinator
        context.coordinator.prepareContentRulesIfNeeded(in: webView) {
            context.coordinator.loadInitial(in: webView, documentURL: documentURL)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Only refresh the callbacks. The document is loaded exactly once (in makeNSView);
        // reloading here would discard the user's in-progress edits and reset the caret. A
        // genuine content change (different document, conflict-reload) arrives as a new
        // SwiftUI identity, which rebuilds the whole view via makeNSView instead.
        context.coordinator.onSnapshot = onSnapshot
        context.coordinator.onNavigationError = onNavigationError
        // The active editor for the host to flush is always the most recently realized one.
        bridge.coordinator = context.coordinator
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: snapshotMessageName, contentWorld: coordinator.world)
        coordinator.webView?.stopLoading()
        if coordinator.bridge?.coordinator === coordinator {
            coordinator.bridge?.coordinator = nil
        }
    }

    /// Turns the body editable, streams debounced snapshots to the host (plus an immediate
    /// one on blur so leaving the editor can't strand the last keystrokes), and neutralizes
    /// link clicks so navigating away can't silently drop unsaved edits.
    private static func editingScript(messageName: String, documentId: String) -> String {
        """
        (function () {
          try { document.body.contentEditable = 'true'; } catch (e) {}
          if (document.body) { document.body.spellcheck = false; }
          function post() {
            try { window.webkit.messageHandlers.\(messageName).postMessage(\(snapshotExpression(documentId: documentId))); } catch (e) {}
          }
          // Initial snapshot of the UNEDITED document, so the host can adopt WebKit's
          // re-serialized form as the clean reference (formatting alone must not read as an
          // edit). Sent before the user can type.
          post();
          var timer = null;
          document.addEventListener('input', function () {
            // Leading edge: the FIRST keystroke after idle posts immediately, so the buffer
            // is marked dirty within one keystroke and no teardown can mistake an edited
            // document for a clean one. Trailing debounce keeps it fresh after that.
            if (!timer) { post(); }
            else { clearTimeout(timer); }
            timer = setTimeout(function () { timer = null; post(); }, 150);
          }, true);
          // Immediate flush when focus leaves, so clicking the sidebar/menu doesn't strand the
          // last edit inside the debounce window.
          document.addEventListener('blur', post, true);
          window.addEventListener('pagehide', post, true);
          document.addEventListener('click', function (e) {
            var node = e.target;
            while (node && node.nodeType === 1) {
              if (node.tagName === 'A' && node.hasAttribute('href')) { e.preventDefault(); return; }
              node = node.parentNode;
            }
          }, true);
        })();
        """
    }

    /// A self-contained JS expression evaluating to `{ doc, body, full }`: the document id,
    /// `body.innerHTML`, and a full doctype+outerHTML serialization with our injected editing
    /// attributes stripped (so they never land on disk).
    ///
    /// The strip happens on a CLONE, never the live `document` — mutating a live attribute on
    /// the editable body mid-typing can cancel an in-flight IME composition (e.g. Korean/CJK
    /// input), so the snapshot must be read-only with respect to the DOM the user is editing.
    static func snapshotExpression(documentId: String) -> String {
        let docLiteral = jsStringLiteral(documentId)
        return """
        (function () {
          var dt = document.doctype, doctype = '';
          if (dt) {
            doctype = '<!DOCTYPE ' + dt.name
              + (dt.publicId ? ' PUBLIC "' + dt.publicId + '"' : '')
              + ((!dt.publicId && dt.systemId) ? ' SYSTEM' : '')
              + (dt.systemId ? ' "' + dt.systemId + '"' : '') + '>';
          }
          var body = document.body ? document.body.innerHTML : '';
          var root = document.documentElement.cloneNode(true);
          var cb = root.querySelector('body');
          if (cb) { cb.removeAttribute('contenteditable'); cb.removeAttribute('spellcheck'); }
          var full = doctype + root.outerHTML;
          return { doc: \(docLiteral), body: body, full: full };
        })()
        """
    }

    /// JSON-encodes a string into a safe JS string literal (handles quotes, backslashes,
    /// control chars). Falls back to an empty literal on the (impossible) encode failure.
    private static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s), let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let documentId: String
        private let baseURL: URL
        private let vaultURL: URL
        private let allowsNetworkAccess: Bool
        let world: WKContentWorld
        var onSnapshot: (String, String, String?) -> Void
        var onNavigationError: (String) -> Void

        weak var webView: WKWebView?
        weak var bridge: VisualEditorBridge?
        private var contentRulesInstalled = false
        private var initialURL: URL?

        init(
            documentId: String,
            baseURL: URL,
            vaultURL: URL,
            allowsNetworkAccess: Bool,
            world: WKContentWorld,
            onSnapshot: @escaping (String, String, String?) -> Void,
            onNavigationError: @escaping (String) -> Void
        ) {
            self.documentId = documentId
            self.baseURL = baseURL
            self.vaultURL = vaultURL
            self.allowsNetworkAccess = allowsNetworkAccess
            self.world = world
            self.onSnapshot = onSnapshot
            self.onNavigationError = onNavigationError
        }

        // MARK: Flush

        /// Pull the freshest DOM snapshot synchronously-awaited and deliver it, so a save or
        /// mode-leave that follows operates on current text rather than the last debounce.
        @MainActor
        func flush() async {
            guard let webView else { return }
            let body = "return \(VisualHTMLEditor.snapshotExpression(documentId: documentId));"
            if let result = try? await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: world) {
                deliver(result)
            }
        }

        private func deliver(_ result: Any?) {
            guard let dict = result as? [String: Any] else { return }
            let doc = dict["doc"] as? String ?? documentId
            let body = dict["body"] as? String ?? ""
            let full = dict["full"] as? String
            onSnapshot(doc, body, full)
        }

        // MARK: Loading

        func prepareContentRulesIfNeeded(in webView: WKWebView, completion: @escaping () -> Void) {
            guard !allowsNetworkAccess, !contentRulesInstalled else {
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

        func loadInitial(in webView: WKWebView, documentURL: URL) {
            let standardized = documentURL.standardizedFileURL
            guard let resourceURL = VaultHTTPServer.resourceURL(
                forFileAt: standardized, baseURL: baseURL, vaultURL: vaultURL
            ) else {
                onNavigationError("Cannot edit a document outside the selected vault.")
                return
            }
            initialURL = resourceURL
            webView.load(URLRequest(url: resourceURL))
        }

        // MARK: WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

            if isMainFrame {
                // Allow ONLY the exact initial document load; cancel any other main-frame
                // navigation (link, meta-refresh, form post) so an edit session can't be
                // navigated out from under the user — which would discard unsaved changes.
                if let url, let initialURL, sameResource(url, initialURL) {
                    decisionHandler(.allow)
                } else {
                    decisionHandler(.cancel)
                }
                return
            }

            // Subframe containment, mirroring the reader's defense and applied in BOTH online
            // and offline modes: our own vault assets (loopback) and the bootstrap about:
            // frames are always allowed; a non-vault file:// frame is NEVER allowed (so an
            // <iframe src="file:///Users/…/.ssh/id_rsa"> can't load even with network on);
            // remote frames load only when the vault has network access.
            if let url, !isAllowedSubframe(url) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func sameResource(_ a: URL, _ b: URL) -> Bool {
            a.standardized == b.standardized
        }

        private func isAllowedSubframe(_ url: URL) -> Bool {
            // Our own vault asset served from the loopback origin.
            if VaultHTTPServer.fileURL(forLoopback: url, baseURL: baseURL, vaultURL: vaultURL) != nil {
                return true
            }
            switch url.scheme?.lowercased() {
            case "about":
                return url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc"
            case "file":
                return false  // non-vault file:// (the in-vault case is the loopback check above)
            default:
                // Remote / other schemes: only when the vault allows network; the content
                // rules also block remote loads when it doesn't.
                return allowsNetworkAccess
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            deliver(message.body)
        }
    }
}
