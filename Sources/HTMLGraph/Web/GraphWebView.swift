import HTMLGraphCore
import SwiftUI
import WebKit

struct GraphWebView: NSViewRepresentable {
    let centerId: String?
    let index: VaultIndex
    let global: Bool
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "graph")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.load(centerId: centerId, index: index, global: global, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(onSelect: onSelect)
        context.coordinator.load(centerId: centerId, index: index, global: global, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "graph")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private var onSelect: (String) -> Void
        private var loadedSignature: String?

        init(onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
        }

        func update(onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
        }

        func load(centerId: String?, index: VaultIndex, global: Bool, in webView: WKWebView) {
            let signature = GraphHTMLBuilder.signature(centerId: centerId, index: index, global: global)
            guard loadedSignature != signature else { return }

            loadedSignature = signature
            webView.loadHTMLString(GraphHTMLBuilder.html(centerId: centerId, index: index, global: global), baseURL: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "graph", let id = message.body as? String else { return }
            onSelect(id)
        }
    }
}

enum GraphHTMLBuilder {
    static func signature(centerId: String?, index: VaultIndex, global: Bool) -> String {
        let documentSignature = index.documents.map { "\($0.id):\($0.title)" }.joined(separator: "|")
        let edgeSignature = index.edges.map { "\($0.sourceId)>\($0.targetId ?? ""):\($0.status.rawValue)" }.joined(separator: "|")
        return "\(global ? "global" : "local"):\(centerId ?? ""):\(documentSignature):\(edgeSignature)"
    }

    static func html(centerId: String?, index: VaultIndex, global: Bool) -> String {
        let graph = makeGraph(centerId: centerId, index: index, global: global)
        let width = 720.0
        let height = 520.0
        let positionedNodes = positions(for: graph.nodes, centerId: centerId, width: width, height: height)
        let documentById = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })

        let edgeMarkup = graph.edges.compactMap { edge -> String? in
            guard let source = positionedNodes[edge.sourceId], let targetId = edge.targetId, let target = positionedNodes[targetId] else {
                return nil
            }
            return #"<line x1="\#(source.x)" y1="\#(source.y)" x2="\#(target.x)" y2="\#(target.y)" />"#
        }.joined(separator: "\n")

        let nodeMarkup = positionedNodes.keys.sorted().compactMap { id -> String? in
            guard let position = positionedNodes[id], let document = documentById[id] else { return nil }
            let radius = id == centerId ? 19 : 15
            let title = escapeHTMLText(document.title)
            let escapedId = escapeHTMLAttribute(id)
            return """
            <g class="node\(id == centerId ? " is-center" : "")" data-id="\(escapedId)" transform="translate(\(position.x) \(position.y))">
              <circle r="\(radius)"></circle>
              <text y="34">\(title)</text>
            </g>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            html, body { width: 100%; height: 100%; margin: 0; background: #f7f7f4; color: #242424; font: 13px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; overflow: hidden; }
            svg { width: 100%; height: 100%; display: block; }
            line { stroke: #b8b8b0; stroke-width: 1.4; }
            .node { cursor: pointer; }
            .node circle { fill: #ffffff; stroke: #6f756b; stroke-width: 1.5; filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.16)); }
            .node.is-center circle { fill: #e5efe0; stroke: #3f6d45; stroke-width: 2; }
            .node text { fill: #242424; text-anchor: middle; paint-order: stroke; stroke: #f7f7f4; stroke-width: 4px; stroke-linejoin: round; font-size: 12px; pointer-events: none; }
            .empty { height: 100%; display: grid; place-items: center; color: #73736d; }
          </style>
        </head>
        <body>
          \(graph.nodes.isEmpty ? #"<div class="empty">No graph nodes</div>"# : """
          <svg viewBox="0 0 \(width) \(height)" role="img" aria-label="HTMLGraph document graph">
            <g class="edges">
              \(edgeMarkup)
            </g>
            <g class="nodes">
              \(nodeMarkup)
            </g>
          </svg>
          """)
          <script>
            document.addEventListener("click", function(event) {
              var node = event.target.closest(".node");
              if (!node) { return; }
              var id = node.getAttribute("data-id");
              if (!id) { return; }
              window.webkit.messageHandlers.graph.postMessage(id);
            });
          </script>
        </body>
        </html>
        """
    }

    private static func makeGraph(centerId: String?, index: VaultIndex, global: Bool) -> (nodes: [DocumentNode], edges: [LinkEdge]) {
        let resolvedEdges = index.edges.filter { $0.status == .resolved && $0.targetId != nil }
        if global {
            return (index.documents, resolvedEdges)
        }

        guard let centerId else {
            return ([], [])
        }

        var ids = Set([centerId])
        for edge in resolvedEdges {
            if edge.sourceId == centerId, let targetId = edge.targetId {
                ids.insert(targetId)
            }
            if edge.targetId == centerId {
                ids.insert(edge.sourceId)
            }
        }

        let nodes = index.documents.filter { ids.contains($0.id) }
        let nodeIds = Set(nodes.map(\.id))
        let edges = resolvedEdges.filter { edge in
            guard let targetId = edge.targetId else { return false }
            return nodeIds.contains(edge.sourceId) && nodeIds.contains(targetId)
        }
        return (nodes, edges)
    }

    private static func positions(for nodes: [DocumentNode], centerId: String?, width: Double, height: Double) -> [String: (x: Double, y: Double)] {
        guard !nodes.isEmpty else { return [:] }

        let sortedNodes = nodes.sorted { $0.id < $1.id }
        let center = (x: width / 2, y: height / 2)
        if sortedNodes.count == 1 {
            return [sortedNodes[0].id: center]
        }

        var positions: [String: (x: Double, y: Double)] = [:]
        let ringNodes: [DocumentNode]
        if let centerId, sortedNodes.contains(where: { $0.id == centerId }) {
            positions[centerId] = center
            ringNodes = sortedNodes.filter { $0.id != centerId }
        } else {
            ringNodes = sortedNodes
        }

        let radius = min(width, height) * 0.34
        for (offset, node) in ringNodes.enumerated() {
            let angle = (Double(offset) / Double(ringNodes.count)) * .pi * 2 - .pi / 2
            positions[node.id] = (
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
        }
        return positions
    }

    private static func escapeHTMLText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeHTMLAttribute(_ text: String) -> String {
        escapeHTMLText(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
