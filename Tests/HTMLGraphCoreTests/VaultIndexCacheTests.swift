import XCTest
@testable import HTMLGraphCore

final class VaultIndexCacheTests: XCTestCase {
    func testRoundTripsIndexCache() throws {
        let cacheRoot = makeTemporaryDirectory().appendingPathComponent("cache", isDirectory: true)
        let cache = VaultIndexCache(rootURL: cacheRoot)
        let document = DocumentNode(
            id: "index.html",
            path: "index.html",
            absolutePath: "/vault/index.html",
            title: "Home",
            contentHash: "abc123",
            lastModified: Date(timeIntervalSince1970: 1_234.5)
        )
        let edge = LinkEdge(
            id: "index.html#link-0",
            sourceId: "index.html",
            targetId: "notes/graph.html",
            href: "./notes/graph.html",
            normalizedTargetPath: "notes/graph.html",
            fragment: "intro",
            linkText: "Graph",
            status: .resolved
        )
        let index = VaultIndex(
            vaultId: "fixture",
            documents: [document],
            edges: [edge],
            backlinks: ["notes/graph.html": [edge]],
            unresolvedLinks: [:],
            lastIndexedAt: Date(timeIntervalSince1970: 1.234567)
        )
        defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }

        try cache.save(index)
        let loaded = try cache.load(vaultId: "fixture")

        XCTAssertEqual(loaded, index)
    }

    func testLoadReturnsNilForMissingCacheEntry() throws {
        let cacheRoot = makeTemporaryDirectory().appendingPathComponent("cache", isDirectory: true)
        let cache = VaultIndexCache(rootURL: cacheRoot)
        defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }

        let loaded = try cache.load(vaultId: "missing")

        XCTAssertNil(loaded)
    }

    func testSavedJSONUsesISO8601FractionalDates() throws {
        let cacheRoot = makeTemporaryDirectory().appendingPathComponent("cache", isDirectory: true)
        let cache = VaultIndexCache(rootURL: cacheRoot)
        let index = VaultIndex(
            vaultId: "fixture",
            documents: [],
            edges: [],
            backlinks: [:],
            unresolvedLinks: [:],
            lastIndexedAt: Date(timeIntervalSince1970: 1.234567)
        )
        defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }

        try cache.save(index)

        let cacheFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil
        ).first)
        let json = try String(contentsOf: cacheFile, encoding: .utf8)

        XCTAssertTrue(json.contains("\"lastIndexedAt\" : \"1970-01-01T00:00:01.23456704616546632Z\""), json)
    }

    func testHostileVaultIdWritesOnlyUnderCacheRoot() throws {
        let tempRoot = makeTemporaryDirectory()
        let cacheRoot = tempRoot.appendingPathComponent("cache", isDirectory: true)
        let cache = VaultIndexCache(rootURL: cacheRoot)
        let index = VaultIndex(
            vaultId: "../vault/a:b?c",
            documents: [],
            edges: [],
            backlinks: [:],
            unresolvedLinks: [:],
            lastIndexedAt: Date(timeIntervalSince1970: 1)
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try cache.save(index)

        let cacheContents = try FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil
        )
        let tempRootContents = try FileManager.default.contentsOfDirectory(
            at: tempRoot,
            includingPropertiesForKeys: nil
        )

        XCTAssertEqual(cacheContents.count, 1)
        XCTAssertTrue(cacheContents.allSatisfy { standardizedPath($0.deletingLastPathComponent()) == standardizedPath(cacheRoot) })
        XCTAssertEqual(tempRootContents.map(standardizedPath), [standardizedPath(cacheRoot)])
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLGraphTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
