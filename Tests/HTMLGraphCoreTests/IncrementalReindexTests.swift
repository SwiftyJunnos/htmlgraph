import XCTest
@testable import HTMLGraphCore

/// Guards the load-bearing invariant of the in-app editor's save path: an incremental
/// single-document reindex must produce a `VaultIndex` field-for-field identical to a
/// full `indexVault` for the same on-disk state (apart from `lastIndexedAt`). If these
/// two drift, a saved edit would update the graph differently than reopening the vault.
final class IncrementalReindexTests: XCTestCase {

    func testTitleChangeMatchesFullReindex() async throws {
        let vaultURL = try makeTemporaryVault(files: [
            "index.html": page(title: "Home", body: #"<a href="./target.html">Target</a>"#),
            "target.html": page(title: "Target", body: "")
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let initial = try await VaultIndexer().indexVault(at: vaultURL)

        try write(page(title: "Home Renamed", body: #"<a href="./target.html">Target</a>"#),
                  to: "index.html", in: vaultURL)

        let patched = try await VaultIndexer().reindexDocument(initial, changedRelativePath: "index.html", vaultURL: vaultURL)
        let full = try await VaultIndexer().indexVault(at: vaultURL)

        XCTAssertEqual(patched.document(id: "index.html")?.title, "Home Renamed")
        assertEquivalent(patched, full)
    }

    func testNewLinkResolvesMatchesFullReindex() async throws {
        // Edit a document that sorts in the MIDDLE of the set so edge-order substitution
        // (not just append) is exercised.
        let vaultURL = try makeTemporaryVault(files: [
            "a.html": page(title: "A", body: #"<a href="./c.html">to C</a>"#),
            "b.html": page(title: "B", body: ""),
            "c.html": page(title: "C", body: "")
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let initial = try await VaultIndexer().indexVault(at: vaultURL)

        try write(page(title: "B", body: #"<a href="./c.html">B to C</a>"#), to: "b.html", in: vaultURL)

        let patched = try await VaultIndexer().reindexDocument(initial, changedRelativePath: "b.html", vaultURL: vaultURL)
        let full = try await VaultIndexer().indexVault(at: vaultURL)

        // c.html now has two backlinks (a and b); the patched index must agree.
        XCTAssertEqual(Set(patched.backlinks["c.html"]?.map(\.sourceId) ?? []), ["a.html", "b.html"])
        assertEquivalent(patched, full)
    }

    func testLinkFlipsToUnresolvedMatchesFullReindex() async throws {
        let vaultURL = try makeTemporaryVault(files: [
            "index.html": page(title: "Home", body: #"<a href="./target.html">Target</a>"#),
            "target.html": page(title: "Target", body: "")
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let initial = try await VaultIndexer().indexVault(at: vaultURL)
        XCTAssertEqual(initial.backlinks["target.html"]?.count, 1)

        try write(page(title: "Home", body: #"<a href="./missing.html">Gone</a>"#),
                  to: "index.html", in: vaultURL)

        let patched = try await VaultIndexer().reindexDocument(initial, changedRelativePath: "index.html", vaultURL: vaultURL)
        let full = try await VaultIndexer().indexVault(at: vaultURL)

        XCTAssertNil(patched.backlinks["target.html"])
        XCTAssertTrue(patched.unresolvedLinks["index.html"]?.contains { $0.href == "./missing.html" } == true)
        assertEquivalent(patched, full)
    }

    func testFragmentOnlySameDocumentLinkIsInNeitherGroup() async throws {
        let vaultURL = try makeTemporaryVault(files: [
            "index.html": page(title: "Home", body: "")
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let initial = try await VaultIndexer().indexVault(at: vaultURL)

        try write(page(title: "Home", body: ##"<a href="#section">Jump</a>"##), to: "index.html", in: vaultURL)

        let patched = try await VaultIndexer().reindexDocument(initial, changedRelativePath: "index.html", vaultURL: vaultURL)
        let full = try await VaultIndexer().indexVault(at: vaultURL)

        XCTAssertTrue(patched.edges.contains { $0.href == "#section" && $0.status == .sameDocument })
        XCTAssertNil(patched.backlinks["index.html"])
        XCTAssertNil(patched.unresolvedLinks["index.html"])
        assertEquivalent(patched, full)
    }

    func testUnknownDocumentThrows() async throws {
        let vaultURL = try makeTemporaryVault(files: [
            "index.html": page(title: "Home", body: "")
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let initial = try await VaultIndexer().indexVault(at: vaultURL)

        do {
            _ = try await VaultIndexer().reindexDocument(initial, changedRelativePath: "does-not-exist.html", vaultURL: vaultURL)
            XCTFail("expected unknownDocument")
        } catch {
            XCTAssertEqual(error as? IncrementalReindexError, .unknownDocument("does-not-exist.html"))
        }
    }

    // MARK: - Helpers

    /// Asserts two indexes are identical except for `lastIndexedAt` (which is always the
    /// wall-clock time of the call and would never match).
    private func assertEquivalent(_ a: VaultIndex, _ b: VaultIndex, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.vaultId, b.vaultId, "vaultId", file: file, line: line)
        XCTAssertEqual(a.documents, b.documents, "documents", file: file, line: line)
        XCTAssertEqual(a.edges, b.edges, "edges (order-sensitive)", file: file, line: line)
        XCTAssertEqual(a.backlinks, b.backlinks, "backlinks", file: file, line: line)
        XCTAssertEqual(a.unresolvedLinks, b.unresolvedLinks, "unresolvedLinks", file: file, line: line)
    }

    private func page(title: String, body: String) -> String {
        """
        <!doctype html>
        <html><head><title>\(title)</title></head><body>
        \(body)
        </body></html>
        """
    }

    private func write(_ contents: String, to path: String, in vaultURL: URL) throws {
        try contents.write(to: vaultURL.appendingPathComponent(path), atomically: true, encoding: .utf8)
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
