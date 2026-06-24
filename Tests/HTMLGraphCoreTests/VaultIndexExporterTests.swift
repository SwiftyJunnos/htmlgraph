import XCTest
@testable import HTMLGraphCore

final class VaultIndexExporterTests: XCTestCase {
    func testWritesStablyNamedGraphJSON() async throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let written = try await VaultIndexExporter().export(
            makeIndex(vaultId: vaultURL.path, lastIndexedAt: Date(timeIntervalSince1970: 1.234567)),
            vaultURL: vaultURL
        )

        XCTAssertEqual(written.lastPathComponent, "graph.json")
        XCTAssertEqual(written.deletingLastPathComponent().lastPathComponent, ".htmlgraph")
        XCTAssertEqual(written, VaultIndexExporter.graphFileURL(forVault: vaultURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
    }

    func testRoundTripsDecodeEqual() async throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        // Millisecond-aligned dates so the interoperable (RFC 3339 ms) encoding
        // round-trips exactly and `decoded.index == index` holds.
        let index = makeIndex(vaultId: vaultURL.path, lastIndexedAt: Date(timeIntervalSince1970: 1_717_171_717))

        let written = try await VaultIndexExporter().export(index, vaultURL: vaultURL)
        let data = try Data(contentsOf: written)
        let decoded = try VaultIndexJSON.decoder.decode(ExportedGraph.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.index, index)
    }

    func testSchemaVersionIsTopLevelSiblingOfGraphFields() async throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let written = try await VaultIndexExporter().export(
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

    func testReExportAtomicallyReplacesPreviousGraph() async throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let exporter = VaultIndexExporter()

        try await exporter.export(
            makeIndex(vaultId: "first", lastIndexedAt: Date(timeIntervalSince1970: 1)),
            vaultURL: vaultURL
        )
        let second = makeIndex(vaultId: "second", lastIndexedAt: Date(timeIntervalSince1970: 2))
        let written = try await exporter.export(second, vaultURL: vaultURL)

        let sidecarContents = try FileManager.default.contentsOfDirectory(
            at: VaultIndexExporter.sidecarDirectory(forVault: vaultURL),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(sidecarContents.count, 1)

        let decoded = try VaultIndexJSON.decoder.decode(ExportedGraph.self, from: Data(contentsOf: written))
        XCTAssertEqual(decoded.index, second)
    }

    func testEncodesInteroperableRFC3339Milliseconds() async throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let preciseDate = Date(timeIntervalSince1970: 1_717_171_717.123456)
        let index = makeIndex(vaultId: vaultURL.path, lastIndexedAt: preciseDate)

        let written = try await VaultIndexExporter().export(index, vaultURL: vaultURL)
        let json = try String(contentsOf: written, encoding: .utf8)

        // Exported timestamps are RFC 3339 with exactly 3 fractional digits — the
        // 17-digit lossless form used by the internal cache breaks standard parsers.
        let rfc3339Millis = try NSRegularExpression(
            pattern: #""lastIndexedAt" : "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z""#
        )
        XCTAssertEqual(
            rfc3339Millis.numberOfMatches(in: json, range: NSRange(json.startIndex..., in: json)),
            1,
            json
        )
        XCTAssertFalse(json.contains(".12345"), "sub-millisecond digits must be dropped: \(json)")

        // Decoding is lossy only below the millisecond.
        let decoded = try VaultIndexJSON.decoder.decode(ExportedGraph.self, from: Data(contentsOf: written))
        XCTAssertEqual(
            decoded.index.lastIndexedAt.timeIntervalSince1970,
            preciseDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testExportedKeysCoverAllVaultIndexFields() async throws {
        let vaultURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let index = makeIndex(vaultId: vaultURL.path, lastIndexedAt: Date(timeIntervalSince1970: 1))

        let written = try await VaultIndexExporter().export(index, vaultURL: vaultURL)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: written)) as? [String: Any]
        let jsonKeys = Set((object ?? [:]).keys)

        // Every stored property of VaultIndex must appear in graph.json; if a new
        // field is added without updating ExportedGraph's flat encoding, it would
        // silently drop out and this guard fails.
        let indexFields = Set(Mirror(reflecting: index).children.compactMap(\.label))
        XCTAssertTrue(
            indexFields.isSubset(of: jsonKeys),
            "graph.json is missing VaultIndex fields: \(indexFields.subtracting(jsonKeys))"
        )
        XCTAssertTrue(jsonKeys.contains("schemaVersion"))
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
