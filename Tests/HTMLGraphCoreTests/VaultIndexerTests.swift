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

        let homeBacklinks = index.backlinks["index.html"] ?? []
        XCTAssertTrue(homeBacklinks.contains { $0.sourceId == "notes/graph.html" })
        XCTAssertTrue(homeBacklinks.contains { $0.sourceId == "notes/backlinks.html" })

        let graphToHome = try XCTUnwrap(index.edges.first { edge in
            edge.sourceId == "notes/graph.html" && edge.href == "../index.html"
        })
        XCTAssertEqual(graphToHome.normalizedTargetPath, "index.html")
        XCTAssertEqual(graphToHome.status, .resolved)
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

    func testDuplicateHrefsFromOneSourceHaveUniqueEdgeIds() throws {
        let vaultURL = try makeTemporaryVault(files: [
            "index.html": """
            <!doctype html>
            <html><head><title>Home</title></head><body>
              <a href="./target.html">Target one</a>
              <a href="./target.html">Target two</a>
            </body></html>
            """,
            "target.html": """
            <!doctype html>
            <html><head><title>Target</title></head><body></body></html>
            """
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let index = try VaultIndexer().indexVault(at: vaultURL)
        let duplicateEdges = index.edges.filter { $0.sourceId == "index.html" && $0.href == "./target.html" }

        XCTAssertEqual(duplicateEdges.count, 2)
        XCTAssertEqual(duplicateEdges.map(\.id), ["index.html#link-0", "index.html#link-1"])
        XCTAssertEqual(Set(duplicateEdges.map(\.id)).count, 2)
    }

    func testExternalSchemeVariantsAreExternal() throws {
        let normalizer = LinkNormalizer()
        let knownDocumentIds: Set<String> = ["index.html"]

        XCTAssertEqual(
            normalizer.normalize(href: "HTTPS://example.com", sourcePath: "index.html", knownDocumentIds: knownDocumentIds).status,
            .external
        )
        XCTAssertEqual(
            normalizer.normalize(href: "tel:+123", sourcePath: "index.html", knownDocumentIds: knownDocumentIds).status,
            .external
        )
        XCTAssertEqual(
            normalizer.normalize(href: "//example.com", sourcePath: "index.html", knownDocumentIds: knownDocumentIds).status,
            .external
        )
        XCTAssertNotEqual(
            normalizer.normalize(href: "./index.html", sourcePath: "index.html", knownDocumentIds: knownDocumentIds).status,
            .external
        )
    }

    func testNormalizerHandlesRootRelativePathsAndRejectsEscapesAboveVaultRoot() {
        let normalizer = LinkNormalizer()
        let knownDocumentIds: Set<String> = ["index.html", "notes/graph.html"]

        let rootRelative = normalizer.normalize(
            href: "/index.html",
            sourcePath: "notes/graph.html",
            knownDocumentIds: knownDocumentIds
        )
        XCTAssertEqual(rootRelative.targetPath, "index.html")
        XCTAssertEqual(rootRelative.status, .resolved)

        let escaped = normalizer.normalize(
            href: "../../outside.html",
            sourcePath: "notes/graph.html",
            knownDocumentIds: knownDocumentIds
        )
        XCTAssertNil(escaped.targetPath)
        XCTAssertEqual(escaped.status, .unresolved)
    }

    func testPercentEncodedLocalHTMLLinksResolveToDecodedDocumentPaths() {
        let normalizer = LinkNormalizer()
        let knownDocumentIds: Set<String> = ["My Page.html", "notes/Other Page.html"]

        let rootDocument = normalizer.normalize(
            href: "./My%20Page.html",
            sourcePath: "index.html",
            knownDocumentIds: knownDocumentIds
        )
        XCTAssertEqual(rootDocument.targetPath, "My Page.html")
        XCTAssertEqual(rootDocument.status, .resolved)

        let nestedDocument = normalizer.normalize(
            href: "./Other%20Page.html#section",
            sourcePath: "notes/index.html",
            knownDocumentIds: knownDocumentIds
        )
        XCTAssertEqual(nestedDocument.targetPath, "notes/Other Page.html")
        XCTAssertEqual(nestedDocument.fragment, "section")
        XCTAssertEqual(nestedDocument.status, .resolved)
    }

    private func makeTemporaryVault(files: [String: String]) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLGraphTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        for (path, contents) in files {
            let fileURL = rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return rootURL
    }
}
