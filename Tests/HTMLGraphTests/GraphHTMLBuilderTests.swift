import Foundation
import HTMLGraphCore
@testable import HTMLGraph
import XCTest

final class GraphHTMLBuilderTests: XCTestCase {
    func testLocalGraphIncludesCenterAndResolvedNeighborsOnlyWithEscapedContent() {
        let index = makeIndex()

        let html = GraphHTMLBuilder.html(centerId: "index.html", index: index, global: false)

        // Graph membership: the center's resolved neighbor is included; the orphan and
        // the unresolved target are not.
        XCTAssertTrue(html.contains("notes/graph.html"))
        XCTAssertFalse(html.contains("notes/orphan.html"))
        XCTAssertFalse(html.contains("missing.html"))

        // Title content is embedded (inside the JSON payload) but its angle brackets are
        // escaped, so a malicious title cannot break out of the <script> block.
        XCTAssertTrue(html.contains("Home"))
        XCTAssertTrue(html.contains("onerror=alert(1)"))
        XCTAssertFalse(html.contains("</script><img src=x onerror=alert(1)>"))

        // The click -> navigate bridge is present.
        XCTAssertTrue(html.contains("window.webkit.messageHandlers.graph.postMessage"))
    }

    func testGlobalGraphIncludesAllDocumentsButOnlyResolvedEdges() {
        let index = makeIndex()

        let html = GraphHTMLBuilder.html(centerId: nil, index: index, global: true)

        XCTAssertTrue(html.contains("index.html"))
        XCTAssertTrue(html.contains("notes/graph.html"))
        XCTAssertTrue(html.contains("notes/orphan.html"))
        XCTAssertFalse(html.contains("missing.html"))
    }


    private func makeIndex() -> VaultIndex {
        let documents = [
            makeDocument(id: "index.html", title: #"<Home>"#),
            makeDocument(id: "notes/graph.html", title: #"Graph </script><img src=x onerror=alert(1)>"#),
            makeDocument(id: "notes/orphan.html", title: "Orphan")
        ]
        let edges = [
            makeEdge(id: "edge-1", sourceId: "index.html", targetId: "notes/graph.html", status: .resolved),
            makeEdge(id: "edge-2", sourceId: "notes/graph.html", targetId: "index.html", status: .resolved),
            makeEdge(id: "edge-3", sourceId: "index.html", targetId: nil, status: .unresolved, href: "missing.html")
        ]
        return VaultIndex(
            vaultId: "test",
            documents: documents,
            edges: edges,
            backlinks: [:],
            unresolvedLinks: [:],
            lastIndexedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeDocument(id: String, title: String) -> DocumentNode {
        DocumentNode(
            id: id,
            path: id,
            absolutePath: "/vault/\(id)",
            title: title,
            contentHash: id,
            lastModified: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeEdge(
        id: String,
        sourceId: String,
        targetId: String?,
        status: LinkStatus,
        href: String = ""
    ) -> LinkEdge {
        LinkEdge(
            id: id,
            sourceId: sourceId,
            targetId: targetId,
            href: href,
            normalizedTargetPath: targetId,
            fragment: nil,
            linkText: "",
            status: status
        )
    }
}
