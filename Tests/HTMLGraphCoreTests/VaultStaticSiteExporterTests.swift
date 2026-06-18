import XCTest
@testable import HTMLGraphCore

final class VaultStaticSiteExporterTests: XCTestCase {
    func testExportsCatalogAndPublicVaultFiles() throws {
        let vaultURL = makeTemporaryDirectory("Vault")
        let outputURL = makeTemporaryDirectory("Export")
        let secretURL = makeTemporaryDirectory("Secret").appendingPathComponent("secret.txt")
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: secretURL.deletingLastPathComponent())
        }

        try write("<html><head><title>Home</title></head><body><img src=\"assets/pic.txt\"></body></html>", to: vaultURL.appendingPathComponent("index.html"))
        try write("<html><head><title>A &amp; B</title></head><body></body></html>", to: vaultURL.appendingPathComponent("notes/My Page & 100%.html"))
        try write("asset", to: vaultURL.appendingPathComponent("assets/pic.txt"))
        try write("<html><head><title>Draft</title></head></html>", to: vaultURL.appendingPathComponent("Inbox/draft.html"))
        try write("{}", to: vaultURL.appendingPathComponent(".htmlgraph/graph.json"))
        try write("agents", to: vaultURL.appendingPathComponent("AGENTS.md"))
        try write("claude", to: vaultURL.appendingPathComponent("CLAUDE.md"))
        try write("secret", to: secretURL)
        try FileManager.default.createSymbolicLink(
            at: vaultURL.appendingPathComponent("secret-link.txt"),
            withDestinationURL: secretURL
        )

        let index = try VaultIndexer().indexVault(at: vaultURL)
        try VaultStaticSiteExporter().export(index: index, vaultURL: vaultURL, to: outputURL)

        XCTAssertTrue(exists(outputURL.appendingPathComponent("index.html")))
        XCTAssertTrue(exists(outputURL.appendingPathComponent(".nojekyll")))
        XCTAssertTrue(exists(outputURL.appendingPathComponent("vault/index.html")))
        XCTAssertTrue(exists(outputURL.appendingPathComponent("vault/notes/My Page & 100%.html")))
        XCTAssertTrue(exists(outputURL.appendingPathComponent("vault/assets/pic.txt")))
        XCTAssertFalse(exists(outputURL.appendingPathComponent("vault/Inbox/draft.html")))
        XCTAssertFalse(exists(outputURL.appendingPathComponent("vault/.htmlgraph/graph.json")))
        XCTAssertFalse(exists(outputURL.appendingPathComponent("vault/AGENTS.md")))
        XCTAssertFalse(exists(outputURL.appendingPathComponent("vault/CLAUDE.md")))
        XCTAssertFalse(exists(outputURL.appendingPathComponent("vault/secret-link.txt")))

        let catalog = try String(contentsOf: outputURL.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(catalog.contains(#"href="vault/index.html""#), catalog)
        XCTAssertTrue(catalog.contains(#"href="vault/notes/My%20Page%20%26%20100%25.html""#), catalog)
        XCTAssertTrue(catalog.contains("A &amp; B"), catalog)
    }

    func testRejectsNonEmptyNonExportDestination() throws {
        let vaultURL = makeTemporaryDirectory("Vault")
        let outputURL = makeTemporaryDirectory("Export")
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        try write("<html><head><title>Home</title></head></html>", to: vaultURL.appendingPathComponent("index.html"))
        try write("keep", to: outputURL.appendingPathComponent("other.txt"))
        let index = try VaultIndexer().indexVault(at: vaultURL)

        XCTAssertThrowsError(try VaultStaticSiteExporter().export(index: index, vaultURL: vaultURL, to: outputURL)) { error in
            XCTAssertEqual(error as? VaultStaticSiteExportError, .destinationNotEmpty)
        }
        XCTAssertEqual(try String(contentsOf: outputURL.appendingPathComponent("other.txt"), encoding: .utf8), "keep")
    }

    func testReusesExistingExportDestination() throws {
        let vaultURL = makeTemporaryDirectory("Vault")
        let outputURL = makeTemporaryDirectory("Export")
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        try write("<html><head><title>Home</title></head></html>", to: vaultURL.appendingPathComponent("index.html"))
        let index = try VaultIndexer().indexVault(at: vaultURL)
        let exporter = VaultStaticSiteExporter()

        try exporter.export(index: index, vaultURL: vaultURL, to: outputURL)
        try write("stale", to: outputURL.appendingPathComponent("vault/stale.txt"))
        try exporter.export(index: index, vaultURL: vaultURL, to: outputURL)

        XCTAssertTrue(exists(outputURL.appendingPathComponent("vault/index.html")))
        XCTAssertFalse(exists(outputURL.appendingPathComponent("vault/stale.txt")))
    }

    func testRejectsDestinationInsideVault() throws {
        let vaultURL = makeTemporaryDirectory("Vault")
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try write("<html><head><title>Home</title></head></html>", to: vaultURL.appendingPathComponent("index.html"))
        let index = try VaultIndexer().indexVault(at: vaultURL)

        XCTAssertThrowsError(
            try VaultStaticSiteExporter().export(
                index: index,
                vaultURL: vaultURL,
                to: vaultURL.appendingPathComponent("public")
            )
        ) { error in
            XCTAssertEqual(error as? VaultStaticSiteExportError, .destinationInsideVault)
        }
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func makeTemporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLGraph\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
