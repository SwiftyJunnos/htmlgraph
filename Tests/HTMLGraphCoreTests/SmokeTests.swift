import XCTest
@testable import HTMLGraphCore

final class SmokeTests: XCTestCase {
    func testDocumentNodeStoresVaultRelativePath() {
        let lastModified = Date(timeIntervalSince1970: 1)
        let node = DocumentNode(
            id: "index.html",
            path: "index.html",
            absolutePath: "/tmp/vault/index.html",
            title: "Home",
            contentHash: "abc",
            lastModified: lastModified
        )

        XCTAssertEqual(node.id, "index.html")
        XCTAssertEqual(node.path, "index.html")
        XCTAssertEqual(node.absolutePath, "/tmp/vault/index.html")
        XCTAssertEqual(node.title, "Home")
        XCTAssertEqual(node.contentHash, "abc")
        XCTAssertEqual(node.lastModified, lastModified)
    }
}
