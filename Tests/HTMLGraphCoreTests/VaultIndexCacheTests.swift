import XCTest
@testable import HTMLGraphCore

final class VaultIndexCacheTests: XCTestCase {
    func testRoundTripsIndexCache() throws {
        let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cache = VaultIndexCache(rootURL: cacheRoot)
        let index = VaultIndex(vaultId: "fixture", documents: [], edges: [], backlinks: [:], unresolvedLinks: [:], lastIndexedAt: Date(timeIntervalSince1970: 1))

        try cache.save(index)
        let loaded = try cache.load(vaultId: "fixture")

        XCTAssertEqual(loaded?.vaultId, "fixture")
        XCTAssertEqual(loaded?.lastIndexedAt, Date(timeIntervalSince1970: 1))
    }
}
