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

    // MARK: - Per-vault security persistence

    func testSecurityStoreRoundTripsPerPath() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VaultSecurityStore(defaults: defaults)

        store.save(VaultSecuritySettings(trustMode: .trusted, allowsNetworkAccess: true), forPath: "/tmp/a")
        store.save(VaultSecuritySettings(trustMode: .safe, allowsNetworkAccess: false), forPath: "/tmp/b")

        XCTAssertEqual(store.settings(forPath: "/tmp/a"), VaultSecuritySettings(trustMode: .trusted, allowsNetworkAccess: true))
        XCTAssertEqual(store.settings(forPath: "/tmp/b"), VaultSecuritySettings(trustMode: .safe, allowsNetworkAccess: false))
        XCTAssertNil(store.settings(forPath: "/tmp/never-seen"))
    }

    func testSecurityStoreReturnsNilOnCorruptData() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "vaultSecuritySettings")
        XCTAssertNil(VaultSecurityStore(defaults: defaults).settings(forPath: "/tmp/a"))
    }

    func testChangingSecuritySettingsPersistsForOpenVault() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VaultSecurityStore(defaults: defaults)
        let appState = AppState(securityStore: store)
        let url = URL(fileURLWithPath: "/tmp/vaultX", isDirectory: true)
        appState.vaultURL = url

        appState.trustMode = .trusted
        appState.allowsNetworkAccess = true

        XCTAssertEqual(
            store.settings(forPath: url.standardizedFileURL.path),
            VaultSecuritySettings(trustMode: .trusted, allowsNetworkAccess: true)
        )
    }

    func testSecuritySettingsAreNotPersistedWithoutAnOpenVault() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VaultSecurityStore(defaults: defaults)
        let appState = AppState(securityStore: store)

        appState.trustMode = .trusted
        appState.allowsNetworkAccess = true

        XCTAssertNil(store.settings(forPath: "/tmp/vaultX"))
    }

    func testSecuritySettingsAreRememberedAcrossVaultSwitches() throws {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let html = "<html><head><title>T</title></head><body></body></html>"
        let vaultA = try makeTemporaryVault(files: ["index.html": html])
        let vaultB = try makeTemporaryVault(files: ["index.html": html])
        defer {
            try? FileManager.default.removeItem(at: vaultA)
            try? FileManager.default.removeItem(at: vaultB)
        }
        let appState = AppState(securityStore: VaultSecurityStore(defaults: defaults))

        // Trust vault A with network access.
        appState.openVault(vaultA)
        appState.trustMode = .trusted
        appState.allowsNetworkAccess = true

        // Switching to a never-trusted vault drops back to Safe.
        appState.openVault(vaultB)
        XCTAssertEqual(appState.trustMode, .safe)
        XCTAssertFalse(appState.allowsNetworkAccess)

        // Reopening vault A restores the remembered posture.
        appState.openVault(vaultA)
        XCTAssertEqual(appState.trustMode, .trusted)
        XCTAssertTrue(appState.allowsNetworkAccess)
    }

    func testGitHubOAuthConnectionStateUsesBundledClientID() throws {
        let credentials = InMemoryGitHubCredentialStore()
        try credentials.save(GitHubOAuthToken(accessToken: "token-a"), clientID: "client-a")

        let appState = AppState(githubCredentialStore: credentials, githubOAuthClientID: " client-a ")

        XCTAssertEqual(appState.githubOAuthClientID, "client-a")
        XCTAssertTrue(appState.hasGitHubOAuthToken)
        XCTAssertTrue(appState.isGitHubOAuthConfigured)
    }

    func testGitHubRepositoryRefreshIgnoresStaleCompletion() async throws {
        let credentials = InMemoryGitHubCredentialStore()
        try credentials.save(GitHubOAuthToken(accessToken: "token-a"), clientID: "client-a")
        let probe = GitHubRepositoryLoaderProbe()
        let appState = AppState(
            githubCredentialStore: credentials,
            githubOAuthClientID: "client-a",
            githubRepositoryLoader: { token in
                try await probe.load(token: token)
            }
        )

        appState.refreshGitHubRepositories()
        await probe.waitForCalls(1)
        appState.refreshGitHubRepositories()
        await probe.waitForCalls(2)

        let fresh = [GitHubRepository(owner: "octocat", name: "fresh", fullName: "octocat/fresh")]
        await probe.resolveCall(1, repositories: fresh)
        try await waitUntil {
            appState.githubRepositories == fresh && !appState.isLoadingGitHubRepositories
        }

        await probe.resolveCall(0, repositories: [
            GitHubRepository(owner: "octocat", name: "stale", fullName: "octocat/stale")
        ])
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(appState.githubRepositories, fresh)
        XCTAssertFalse(appState.isLoadingGitHubRepositories)
    }

    private func scratchDefaults() -> (UserDefaults, String) {
        let suite = "AppStateSecurityTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for condition.", file: file, line: line)
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

    func testDocumentTreeBuildsFolderHierarchyFoldersBeforeDocuments() throws {
        let html = { (title: String) in "<html><head><title>\(title)</title></head><body></body></html>" }
        let vaultURL = try makeTemporaryVault(files: [
            "index.html": html("Home"),
            "concepts/backlinks.html": html("Backlinks"),
            "concepts/graph.html": html("Graph"),
            "guides/start.html": html("Start")
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let index = try VaultIndexer().indexVault(at: vaultURL)

        let tree = DocumentTreeBuilder.build(from: index.documents)

        // Folders (sorted) first, then root-level documents.
        XCTAssertEqual(tree.map(\.name), ["concepts", "guides", "index.html"])
        XCTAssertNil(tree[0].document)
        XCTAssertEqual(tree[0].children.map(\.name), ["backlinks.html", "graph.html"])
        XCTAssertNotNil(tree[2].document)
        XCTAssertTrue(tree[2].children.isEmpty)
    }

    func testCreateDocumentForUnresolvedWritesStubHtml() throws {
        let vaultURL = try makeTemporaryVault(files: [
            "index.html": "<html><head><title>Home</title></head><body></body></html>"
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let appState = AppState()
        appState.vaultURL = vaultURL

        let edge = LinkEdge(
            id: "index.html#link-0",
            sourceId: "index.html",
            targetId: nil,
            href: "concepts/new-note.html",
            normalizedTargetPath: "concepts/new-note.html",
            fragment: nil,
            linkText: "New Note",
            status: .unresolved
        )

        appState.createDocument(forUnresolved: edge)

        let created = vaultURL.appendingPathComponent("concepts/new-note.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        let html = try String(contentsOf: created, encoding: .utf8)
        XCTAssertTrue(html.contains("<title>New Note</title>"))
        XCTAssertTrue(html.contains("<h1>New Note</h1>"))
        XCTAssertNil(appState.errorMessage)
    }

    func testCreateDocumentIgnoresNonHtmlTarget() throws {
        let vaultURL = try makeTemporaryVault(files: [
            "index.html": "<html><head><title>Home</title></head><body></body></html>"
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let appState = AppState()
        appState.vaultURL = vaultURL

        let edge = LinkEdge(
            id: "index.html#link-0",
            sourceId: "index.html",
            targetId: nil,
            href: "notes.txt",
            normalizedTargetPath: "notes.txt",
            fragment: nil,
            linkText: "Notes",
            status: .unresolved
        )

        appState.createDocument(forUnresolved: edge)

        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL.appendingPathComponent("notes.txt").path))
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

private actor GitHubRepositoryLoaderProbe {
    private var continuations: [CheckedContinuation<[GitHubRepository], any Error>] = []

    func load(token: String) async throws -> [GitHubRepository] {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForCalls(_ count: Int) async {
        while continuations.count < count {
            await Task.yield()
        }
    }

    func resolveCall(_ index: Int, repositories: [GitHubRepository]) {
        continuations[index].resume(returning: repositories)
    }
}

private final class InMemoryGitHubCredentialStore: GitHubCredentialStoring {
    private var tokens: [String: GitHubOAuthToken] = [:]

    func load(clientID: String) throws -> GitHubOAuthToken? {
        tokens[clientID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func save(_ token: GitHubOAuthToken, clientID: String) throws {
        tokens[clientID.trimmingCharacters(in: .whitespacesAndNewlines)] = token
    }

    func delete(clientID: String) {
        tokens.removeValue(forKey: clientID.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
