import XCTest
@testable import HTMLGraphCore

final class InboxScannerTests: XCTestCase {
    func testScansOnlyHTMLFilesUnderVaultInbox() async throws {
        let vaultURL = try makeTemporaryVault(files: [
            "index.html": "<html><head><title>Home</title></head><body></body></html>",
            "Inbox/idea.html": "<html><head><title>AI Idea</title></head><body></body></html>",
            "Inbox/nested/research.htm": "<html><body><h1>Research Note</h1></body></html>",
            "Inbox/draft.txt": "not html",
            "Notes/regular.html": "<html><head><title>Regular</title></head><body></body></html>"
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let items = try await InboxScanner().scanInbox(at: vaultURL)

        XCTAssertEqual(items.map(\.path), ["Inbox/idea.html", "Inbox/nested/research.htm"])
        XCTAssertEqual(items.map(\.title), ["AI Idea", "Research Note"])
        XCTAssertTrue(items.allSatisfy { $0.absolutePath.hasPrefix(vaultURL.path) })
    }

    func testMissingInboxReturnsEmptyList() async throws {
        let vaultURL = try makeTemporaryVault(files: [
            "index.html": "<html><head><title>Home</title></head><body></body></html>"
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let items = try await InboxScanner().scanInbox(at: vaultURL)
        XCTAssertEqual(items, [])
    }

    private func makeTemporaryVault(files: [String: String]) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLGraphInboxTests-\(UUID().uuidString)", isDirectory: true)

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
