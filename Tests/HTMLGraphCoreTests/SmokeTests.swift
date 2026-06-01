import XCTest
@testable import HTMLGraphCore

final class SmokeTests: XCTestCase {
    func testDocumentNodeStoresVaultRelativePath() {
        let node = DocumentNode(
            id: "index.html",
            path: "index.html",
            absolutePath: "/tmp/vault/index.html",
            title: "Home",
            contentHash: "abc",
            lastModified: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(node.id, "index.html")
        XCTAssertEqual(node.title, "Home")
    }
}
