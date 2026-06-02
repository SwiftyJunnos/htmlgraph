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
}
