import XCTest
@testable import HTMLGraphCore

final class VaultIndexExporterTests: XCTestCase {
    func testWritesStablyNamedGraphJSON() throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let written = try VaultIndexExporter().export(
            makeIndex(vaultId: vaultURL.path, lastIndexedAt: Date(timeIntervalSince1970: 1.234567)),
            vaultURL: vaultURL
        )

        XCTAssertEqual(written.lastPathComponent, "graph.json")
        XCTAssertEqual(written.deletingLastPathComponent().lastPathComponent, ".htmlgraph")
        XCTAssertEqual(written, VaultIndexExporter.graphFileURL(forVault: vaultURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
    }

    func testRoundTripsDecodeEqual() throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let index = makeIndex(vaultId: vaultURL.path, lastIndexedAt: Date(timeIntervalSince1970: 1.234567))

        let written = try VaultIndexExporter().export(index, vaultURL: vaultURL)
        let data = try Data(contentsOf: written)
        let decoded = try VaultIndexJSON.decoder.decode(ExportedGraph.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.index, index)
    }

    func testSchemaVersionIsTopLevelSiblingOfGraphFields() throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let written = try VaultIndexExporter().export(
            makeIndex(vaultId: vaultURL.path, lastIndexedAt: Date(timeIntervalSince1970: 1)),
            vaultURL: vaultURL
        )
        let json = try String(contentsOf: written, encoding: .utf8)

        // Pretty-printed + sorted keys puts schemaVersion alongside documents/edges
        // at the top level (two-space indent), not nested under an "index" key.
        XCTAssertTrue(json.contains("\n  \"schemaVersion\" : 1"), json)
        XCTAssertTrue(json.contains("\n  \"documents\" :"), json)
        XCTAssertFalse(json.contains("\"index\" :"), json)
    }

    func testReExportAtomicallyReplacesPreviousGraph() throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let exporter = VaultIndexExporter()

        try exporter.export(
            makeIndex(vaultId: "first", lastIndexedAt: Date(timeIntervalSince1970: 1)),
            vaultURL: vaultURL
        )
        let second = makeIndex(vaultId: "second", lastIndexedAt: Date(timeIntervalSince1970: 2))
        let written = try exporter.export(second, vaultURL: vaultURL)

        let sidecarContents = try FileManager.default.contentsOfDirectory(
            at: VaultIndexExporter.sidecarDirectory(forVault: vaultURL),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(sidecarContents.count, 1)

        let decoded = try VaultIndexJSON.decoder.decode(ExportedGraph.self, from: Data(contentsOf: written))
        XCTAssertEqual(decoded.index, second)
    }

    func testRoundTripsHighPrecisionDateExactly() throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let date = Date(timeIntervalSince1970: 1_717_171_717.123456)
        let index = makeIndex(vaultId: vaultURL.path, lastIndexedAt: date)

        let written = try VaultIndexExporter().export(index, vaultURL: vaultURL)
        let decoded = try VaultIndexJSON.decoder.decode(ExportedGraph.self, from: Data(contentsOf: written))

        XCTAssertEqual(decoded.index.lastIndexedAt, date)
    }

    private func makeIndex(vaultId: String, lastIndexedAt: Date) -> VaultIndex {
        let document = DocumentNode(
            id: "index.html",
            path: "index.html",
            absolutePath: "\(vaultId)/index.html",
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
        return VaultIndex(
            vaultId: vaultId,
            documents: [document],
            edges: [edge],
            backlinks: ["notes/graph.html": [edge]],
            unresolvedLinks: [:],
            lastIndexedAt: lastIndexedAt
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLGraphTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
