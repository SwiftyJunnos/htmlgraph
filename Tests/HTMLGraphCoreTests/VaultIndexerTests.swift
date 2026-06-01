import XCTest
@testable import HTMLGraphCore

final class VaultIndexerTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures/sample-vault")
    }

    func testIndexesDocumentsAndBuildsBacklinks() throws {
        let index = try VaultIndexer().indexVault(at: fixtureURL)

        XCTAssertEqual(index.documents.count, 6)
        XCTAssertEqual(index.document(id: "index.html")?.title, "HTMLGraph Home")

        let graphBacklinks = index.backlinks["notes/graph.html"] ?? []
        XCTAssertTrue(graphBacklinks.contains { $0.sourceId == "index.html" })
    }

    func testClassifiesExternalSameDocumentAndUnresolvedLinks() throws {
        let index = try VaultIndexer().indexVault(at: fixtureURL)

        XCTAssertTrue(index.edges.contains { edge in
            edge.href == "https://obsidian.md/" && edge.status == .external
        })
        XCTAssertTrue(index.edges.contains { edge in
            edge.href == "#local-section" && edge.status == .sameDocument
        })
        XCTAssertTrue(index.unresolvedLinks["index.html"]?.contains { edge in
            edge.href == "./notes/missing.html"
        } == true)
    }
}
