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
        let degreeById = degrees(graph.edges)
        let payload = GraphPayload(
            nodes: graph.nodes.map { node in
                GraphPayload.Node(
                    id: node.id,
                    title: node.title,
                    degree: degreeById[node.id] ?? 0,
                    isCenter: node.id == centerId
                )
            },
            edges: graph.edges.compactMap { edge in
                edge.targetId.map { GraphPayload.Edge(source: edge.sourceId, target: $0) }
            }
        )

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            :root { color-scheme: light dark; }
            html, body { width: 100%; height: 100%; margin: 0; overflow: hidden;
              font: 12px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              background: #f7f7f4; }
            @media (prefers-color-scheme: dark) { html, body { background: #1f201e; } }
            #graph { width: 100%; height: 100%; display: block; cursor: grab; }
            #graph.grabbing { cursor: grabbing; }
            #empty:not([hidden]) { position: absolute; inset: 0; display: grid; place-items: center; color: #8a8a84; }
          </style>
        </head>
        <body>
          <canvas id="graph"></canvas>
          <div id="empty" hidden>No linked documents</div>
          <script>
            const DATA = \(embeddableJSON(payload));
            const canvas = document.getElementById("graph");
            const empty = document.getElementById("empty");
            const ctx = canvas.getContext("2d");

            if (!DATA.nodes.length) { empty.hidden = false; }

            const dark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
            const COLORS = dark
              ? { edge: "rgba(150,155,150,0.35)", edgeDim: "rgba(150,155,150,0.12)", edgeHot: "rgba(120,196,134,0.95)",
                  fill: "#2c2f2c", stroke: "#9aa39a", center: "#1f3a26", centerStroke: "#79c486",
                  label: "#e7e7e2", halo: "#1c1d1b", dim: 0.18 }
              : { edge: "rgba(150,150,145,0.55)", edgeDim: "rgba(150,150,145,0.18)", edgeHot: "rgba(63,109,69,0.95)",
                  fill: "#ffffff", stroke: "#6f756b", center: "#e5efe0", centerStroke: "#3f6d45",
                  label: "#242424", halo: "#f7f7f4", dim: 0.22 };

            let dpr = 1, width = 0, height = 0;
            function resize() {
              dpr = window.devicePixelRatio || 1;
              width = canvas.clientWidth; height = canvas.clientHeight;
              canvas.width = Math.max(1, Math.round(width * dpr));
              canvas.height = Math.max(1, Math.round(height * dpr));
            }

            const nodes = DATA.nodes.map((n, i) => {
              const a = (i / Math.max(1, DATA.nodes.length)) * Math.PI * 2;
              return { id: n.id, title: n.title, degree: n.degree, isCenter: n.isCenter,
                x: Math.cos(a) * 100, y: Math.sin(a) * 100, vx: 0, vy: 0, fixed: false };
            });
            const byId = {};
            nodes.forEach(n => { byId[n.id] = n; });
            const edges = DATA.edges.map(e => ({ s: byId[e.source], t: byId[e.target] })).filter(e => e.s && e.t);
            const neighbors = {};
            nodes.forEach(n => { neighbors[n.id] = new Set(); });
            edges.forEach(e => { neighbors[e.s.id].add(e.t.id); neighbors[e.t.id].add(e.s.id); });

            function radius(n) { return 6 + Math.min(11, n.degree * 1.7) + (n.isCenter ? 3 : 0); }

            let scale = 1, panX = 0, panY = 0, fitted = false, userMoved = false;
            const sx = n => n.x * scale + width / 2 + panX;
            const sy = n => n.y * scale + height / 2 + panY;
            const worldX = px => (px - width / 2 - panX) / scale;
            const worldY = py => (py - height / 2 - panY) / scale;

            let alpha = 1;
            function simulate() {
              const repel = 5200, spring = 0.025, springLen = 92, pull = 0.012;
              for (let i = 0; i < nodes.length; i++) {
                const a = nodes[i];
                for (let j = i + 1; j < nodes.length; j++) {
                  const b = nodes[j];
                  let dx = a.x - b.x, dy = a.y - b.y, d2 = dx * dx + dy * dy;
                  if (d2 < 0.01) { d2 = 0.01; dx = 0.1; }
                  const d = Math.sqrt(d2), f = repel / d2;
                  const fx = (dx / d) * f, fy = (dy / d) * f;
                  a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
                }
              }
              edges.forEach(e => {
                let dx = e.t.x - e.s.x, dy = e.t.y - e.s.y;
                const d = Math.sqrt(dx * dx + dy * dy) || 0.01;
                const f = (d - springLen) * spring;
                const fx = (dx / d) * f, fy = (dy / d) * f;
                e.s.vx += fx; e.s.vy += fy; e.t.vx -= fx; e.t.vy -= fy;
              });
              nodes.forEach(n => {
                if (n.isCenter) { n.x = 0; n.y = 0; n.vx = 0; n.vy = 0; return; }
                n.vx += -n.x * pull; n.vy += -n.y * pull;
                if (n.fixed) { n.vx = 0; n.vy = 0; return; }
                n.vx *= 0.86; n.vy *= 0.86;
                n.x += n.vx * alpha; n.y += n.vy * alpha;
              });
            }

            function fitView() {
              if (!nodes.length) return;
              let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
              nodes.forEach(n => {
                minX = Math.min(minX, n.x); maxX = Math.max(maxX, n.x);
                minY = Math.min(minY, n.y); maxY = Math.max(maxY, n.y);
              });
              const pad = 70;
              const bw = (maxX - minX) || 1, bh = (maxY - minY) || 1;
              scale = Math.min(2, Math.max(0.35, Math.min((width - pad) / bw, (height - pad) / bh)));
              panX = -((minX + maxX) / 2) * scale;
              panY = -((minY + maxY) / 2) * scale;
            }

            function drawArrow(fromN, toN, color) {
              const a = { x: sx(fromN), y: sy(fromN) }, b = { x: sx(toN), y: sy(toN) };
              let dx = b.x - a.x, dy = b.y - a.y;
              const d = Math.hypot(dx, dy) || 1; dx /= d; dy /= d;
              const tipX = b.x - dx * (radius(toN) * scale + 2);
              const tipY = b.y - dy * (radius(toN) * scale + 2);
              const size = 5.5;
              ctx.fillStyle = color;
              ctx.beginPath();
              ctx.moveTo(tipX, tipY);
              ctx.lineTo(tipX - dx * size - dy * size * 0.6, tipY - dy * size + dx * size * 0.6);
              ctx.lineTo(tipX - dx * size + dy * size * 0.6, tipY - dy * size - dx * size * 0.6);
              ctx.closePath();
              ctx.fill();
            }

            let hovered = null;
            function draw() {
              ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
              ctx.clearRect(0, 0, width, height);
              const hl = hovered ? neighbors[hovered.id] : null;

              ctx.lineWidth = 1.3;
              edges.forEach(e => {
                const hot = hovered && (e.s.id === hovered.id || e.t.id === hovered.id);
                const color = hot ? COLORS.edgeHot : (hovered ? COLORS.edgeDim : COLORS.edge);
                ctx.strokeStyle = color;
                ctx.beginPath();
                ctx.moveTo(sx(e.s), sy(e.s));
                ctx.lineTo(sx(e.t), sy(e.t));
                ctx.stroke();
                drawArrow(e.s, e.t, color);
              });

              const showAllLabels = nodes.length <= 28;
              nodes.forEach(n => {
                const x = sx(n), y = sy(n), r = radius(n) * scale;
                const faded = hovered && n.id !== hovered.id && !(hl && hl.has(n.id));
                ctx.globalAlpha = faded ? COLORS.dim : 1;

                ctx.beginPath();
                ctx.arc(x, y, r, 0, Math.PI * 2);
                ctx.fillStyle = n.isCenter ? COLORS.center : COLORS.fill;
                ctx.fill();
                ctx.lineWidth = n.isCenter ? 2.2 : 1.6;
                ctx.strokeStyle = n.isCenter ? COLORS.centerStroke : COLORS.stroke;
                ctx.stroke();

                const labelled = showAllLabels || n.isCenter || (hovered && (n.id === hovered.id || (hl && hl.has(n.id))));
                if (labelled) {
                  ctx.font = (n.isCenter ? "600 " : "") + "12px -apple-system, sans-serif";
                  ctx.textAlign = "center";
                  ctx.textBaseline = "top";
                  const label = n.title.length > 28 ? n.title.slice(0, 27) + "…" : n.title;
                  ctx.lineWidth = 3.5;
                  ctx.strokeStyle = COLORS.halo;
                  ctx.lineJoin = "round";
                  ctx.strokeText(label, x, y + r + 4);
                  ctx.fillStyle = COLORS.label;
                  ctx.fillText(label, x, y + r + 4);
                }
                ctx.globalAlpha = 1;
              });
            }

            function nodeAt(px, py) {
              for (let i = nodes.length - 1; i >= 0; i--) {
                const n = nodes[i];
                const r = radius(n) * scale + 4;
                if (Math.hypot(px - sx(n), py - sy(n)) <= r) return n;
              }
              return null;
            }

            function frame() {
              if (alpha > 0.02 || dragNode) {
                for (let k = 0; k < 2; k++) simulate();
                alpha *= 0.985;
                if (!fitted && !userMoved && alpha < 0.25) { fitView(); fitted = true; }
              }
              draw();
              requestAnimationFrame(frame);
            }

            // Interaction. macOS WKWebView delivers Mouse Events reliably (Pointer Events
            // are flaky here), so use mousedown/move/up; move + up live on window so a drag
            // keeps tracking when the cursor leaves the canvas.
            let dragNode = null, panning = false, lastX = 0, lastY = 0, moved = 0;
            function pos(e) {
              const r = canvas.getBoundingClientRect();
              return { x: e.clientX - r.left, y: e.clientY - r.top };
            }
            function inside(p) { return p.x >= 0 && p.y >= 0 && p.x <= width && p.y <= height; }
            function setCursor(c) { canvas.style.cursor = c; document.body.style.cursor = c; }
            window.addEventListener("mousedown", e => {
              if (e.button !== 0) return;
              const p = pos(e);
              if (!inside(p)) return;
              lastX = p.x; lastY = p.y; moved = 0;
              const n = nodeAt(p.x, p.y);
              if (n) { dragNode = n; n.fixed = true; alpha = Math.max(alpha, 0.5); }
              else { panning = true; }
              setCursor("grabbing");
              e.preventDefault();
            });
            window.addEventListener("mousemove", e => {
              const p = pos(e);
              if (dragNode) {
                dragNode.x = worldX(p.x); dragNode.y = worldY(p.y);
                moved += Math.hypot(p.x - lastX, p.y - lastY);
                alpha = Math.max(alpha, 0.3);
              } else if (panning) {
                panX += p.x - lastX; panY += p.y - lastY; userMoved = true;
                moved += Math.hypot(p.x - lastX, p.y - lastY);
              } else if (inside(p)) {
                const n = nodeAt(p.x, p.y);
                if (n !== hovered) hovered = n;
                setCursor(n ? "pointer" : "grab");
              }
              lastX = p.x; lastY = p.y;
            });
            window.addEventListener("mouseup", e => {
              if (dragNode) {
                if (moved < 4) { window.webkit.messageHandlers.graph.postMessage(dragNode.id); }
                dragNode.fixed = false; dragNode = null;
              }
              panning = false;
              const p = pos(e);
              setCursor(inside(p) && hovered ? "pointer" : "grab");
            });
            window.addEventListener("wheel", e => {
              const p = pos(e);
              if (!inside(p)) return;
              e.preventDefault();
              const wx = worldX(p.x), wy = worldY(p.y);
              const factor = Math.exp(-e.deltaY * 0.0015);
              scale = Math.min(4, Math.max(0.2, scale * factor));
              panX = p.x - width / 2 - wx * scale;
              panY = p.y - height / 2 - wy * scale;
              userMoved = true;
            }, { passive: false });
            window.addEventListener("dblclick", e => {
              if (!inside(pos(e))) return;
              fitView(); userMoved = false;
            });

            const ro = new ResizeObserver(() => { resize(); if (!userMoved) fitView(); });
            ro.observe(canvas);
            resize();
            requestAnimationFrame(frame);
          </script>
        </body>
        </html>
        """
    }

    private struct GraphPayload: Encodable {
        struct Node: Encodable {
            let id: String
            let title: String
            let degree: Int
            let isCenter: Bool
        }

        struct Edge: Encodable {
            let source: String
            let target: String
        }

        let nodes: [Node]
        let edges: [Edge]
    }

    private static func embeddableJSON(_ payload: GraphPayload) -> String {
        guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else {
            return #"{"nodes":[],"edges":[]}"#
        }
        return json
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func degrees(_ edges: [LinkEdge]) -> [String: Int] {
        var result: [String: Int] = [:]
        for edge in edges {
            result[edge.sourceId, default: 0] += 1
            if let targetId = edge.targetId {
                result[targetId, default: 0] += 1
            }
        }
        return result
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
}
