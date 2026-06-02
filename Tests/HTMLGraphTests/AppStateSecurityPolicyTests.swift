@testable import HTMLGraph
import HTMLGraphCore
import XCTest

@MainActor
final class AppStateSecurityPolicyTests: XCTestCase {
    func testSafeModeIsDefaultAndDoesNotRetainNetworkAccess() {
        let appState = AppState()

        XCTAssertEqual(appState.securityPolicy, VaultSecurityPolicy(mode: .safe, allowsNetworkAccess: false))

        appState.trustMode = .trusted
        appState.allowsNetworkAccess = true
        XCTAssertEqual(appState.securityPolicy, VaultSecurityPolicy(mode: .trusted, allowsNetworkAccess: true))

        appState.trustMode = .safe
        XCTAssertEqual(appState.securityPolicy, VaultSecurityPolicy(mode: .safe, allowsNetworkAccess: false))
    }

    func testVaultStatusPresentationReflectsClosedIndexingAndOpenStates() {
        let appState = AppState()

        XCTAssertEqual(appState.openVaultButtonTitle, "Open Vault")
        XCTAssertNil(appState.vaultDisplayName)
        XCTAssertEqual(appState.vaultStatusText, "No vault open")

        appState.vaultURL = URL(fileURLWithPath: "/Users/test/Documents/sample-vault", isDirectory: true)
        appState.isIndexing = true

        XCTAssertEqual(appState.openVaultButtonTitle, "Change Vault")
        XCTAssertEqual(appState.vaultDisplayName, "sample-vault")
        XCTAssertEqual(appState.vaultDisplayPath, "/Users/test/Documents/sample-vault")
        XCTAssertEqual(appState.vaultStatusText, "Indexing vault...")

        appState.isIndexing = false
        appState.index = VaultIndex(
            vaultId: "sample-vault",
            documents: [
                DocumentNode(
                    id: "index.html",
                    path: "index.html",
                    absolutePath: "/Users/test/Documents/sample-vault/index.html",
                    title: "Home",
                    contentHash: "hash",
                    lastModified: Date(timeIntervalSince1970: 0)
                ),
                DocumentNode(
                    id: "notes/graph.html",
                    path: "notes/graph.html",
                    absolutePath: "/Users/test/Documents/sample-vault/notes/graph.html",
                    title: "Graph",
                    contentHash: "hash",
                    lastModified: Date(timeIntervalSince1970: 1)
                )
            ],
            edges: [],
            backlinks: [:],
            unresolvedLinks: [:],
            lastIndexedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(appState.vaultStatusText, "2 documents")
    }

    func testRefreshInboxLoadsPendingInboxItems() throws {
        let vaultURL = try makeTemporaryVault(files: [
            "Inbox/idea.html": "<html><head><title>AI Idea</title></head><body></body></html>"
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let appState = AppState()
        appState.vaultURL = vaultURL

        try appState.refreshInbox()

        XCTAssertEqual(appState.inboxItems.map(\.path), ["Inbox/idea.html"])
        XCTAssertEqual(appState.selectedInboxItem?.title, nil)

        appState.selectInboxItem("Inbox/idea.html")
        XCTAssertEqual(appState.selectedInboxItem?.title, "AI Idea")
        XCTAssertNil(appState.selectedDocumentId)
    }

    func testAcceptInboxItemMovesFileRefreshesInboxAndStartsReindexing() throws {
        let vaultURL = try makeTemporaryVault(files: [
            "Inbox/idea.html": "<html><head><title>AI Idea</title></head><body></body></html>"
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let appState = AppState()
        appState.vaultURL = vaultURL
        try appState.refreshInbox()
        let item = try XCTUnwrap(appState.inboxItems.first)

        let destinationURL = vaultURL.appendingPathComponent("Notes/idea.html")
        try appState.acceptInboxItem(item, to: destinationURL)

        XCTAssertEqual(appState.inboxItems, [])
        XCTAssertNil(appState.selectedInboxItemId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertTrue(appState.isIndexing || appState.index?.document(id: "Notes/idea.html") != nil)
    }

    func testAddToVaultFilesItemToRootAndRemovesItFromInbox() throws {
        let vaultURL = try makeTemporaryVault(files: [
            "Inbox/draft.html": "<html><head><title>Draft</title></head><body></body></html>"
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let appState = AppState()
        appState.vaultURL = vaultURL
        try appState.refreshInbox()
        let item = try XCTUnwrap(appState.inboxItems.first)

        appState.addToVault(item, folder: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultURL.appendingPathComponent("draft.html").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL.appendingPathComponent("Inbox/draft.html").path))
        XCTAssertEqual(appState.inboxItems, [])
        XCTAssertNil(appState.errorMessage)
    }

    func testVaultFoldersListsDistinctDocumentFoldersExcludingRoot() throws {
        let html = "<html><head><title>T</title></head><body></body></html>"
        let vaultURL = try makeTemporaryVault(files: [
            "index.html": html,
            "concepts/a.html": html,
            "concepts/b.html": html,
            "guides/g.html": html
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let appState = AppState()
        appState.index = try VaultIndexer().indexVault(at: vaultURL)

        XCTAssertEqual(appState.vaultFolders, ["concepts", "guides"])
    }

    private func makeTemporaryVault(files: [String: String]) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLGraphAppStateTests-\(UUID().uuidString)", isDirectory: true)

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
