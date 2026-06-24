@testable import HTMLGraph
import XCTest

@MainActor
final class RecentVaultsTests: XCTestCase {
    private func scratch() -> (UserDefaults, String) {
        let suite = "RecentVaultsTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func vault(_ path: String, name: String? = nil) -> RecentVault {
        RecentVault(
            bookmarkData: Data(path.utf8),
            displayName: name ?? (path as NSString).lastPathComponent,
            path: path,
            lastOpened: Date()
        )
    }

    // MARK: - RecentVaultsStore (pure persistence)

    func testStoreRoundTrips() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentVaultsStore(defaults: defaults)

        store.save([vault("/tmp/a"), vault("/tmp/b")])

        XCTAssertEqual(store.load().map(\.path), ["/tmp/a", "/tmp/b"])
    }

    func testStoreReturnsEmptyOnMissingKey() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(RecentVaultsStore(defaults: defaults).load(), [])
    }

    func testStoreReturnsEmptyOnCorruptData() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "recentVaults")
        XCTAssertEqual(RecentVaultsStore(defaults: defaults).load(), [])
    }

    func testStoreCapsToMaxKeepingNewestFirst() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentVaultsStore(defaults: defaults)

        store.save((0..<20).map { vault("/tmp/v\($0)") })

        let loaded = store.load()
        XCTAssertEqual(loaded.count, RecentVaultsStore.maxCount)
        XCTAssertEqual(loaded.first?.path, "/tmp/v0")
    }

    // MARK: - AppState integration (no bookmark resolution)

    func testAppStateLoadsRecentVaultsFromStore() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentVaultsStore(defaults: defaults)
        store.save([vault("/tmp/a", name: "A"), vault("/tmp/b", name: "B")])

        let appState = AppState(recentsStore: store)

        XCTAssertEqual(appState.recentVaults.map(\.displayName), ["A", "B"])
    }

    func testRemoveRecentAndClearRecentsPersist() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentVaultsStore(defaults: defaults)
        let a = vault("/tmp/a")
        store.save([a, vault("/tmp/b")])
        let appState = AppState(recentsStore: store)

        appState.removeRecent(a)
        XCTAssertEqual(appState.recentVaults.map(\.path), ["/tmp/b"])
        XCTAssertEqual(store.load().map(\.path), ["/tmp/b"])

        appState.clearRecents()
        XCTAssertTrue(appState.recentVaults.isEmpty)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testOpenRecentDropsUnresolvableEntryAndReportsError() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentVaultsStore(defaults: defaults)
        let gone = vault("/tmp/gone")
        store.save([gone])
        let appState = AppState(recentsStore: store)

        appState.openRecent(gone)

        XCTAssertTrue(appState.recentVaults.isEmpty)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertNotNil(appState.errorMessage)
    }

    func testAutomaticOpenRecentDropDoesNotReportError() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentVaultsStore(defaults: defaults)
        let gone = vault("/tmp/gone")
        store.save([gone])
        let appState = AppState(recentsStore: store)

        appState.openRecent(gone, isAutomatic: true)

        XCTAssertTrue(appState.recentVaults.isEmpty)
        XCTAssertNil(appState.errorMessage)
    }

    // MARK: - Remote recents + Keychain credentials
    //
    // Hosts use the `.invalid` TLD (RFC 6761 — guaranteed not to resolve) so the async
    // indexing connection kicked off by `openRemoteVault` fails fast and never touches the
    // network; every assertion here is on the synchronous bookkeeping done before that.

    private final class InMemoryCredentialStore: CredentialStore {
        var passwords: [String: String] = [:]
        func password(forIdentity identity: String) -> String? { passwords[identity] }
        func setPassword(_ password: String, forIdentity identity: String) { passwords[identity] = password }
        func removePassword(forIdentity identity: String) { passwords[identity] = nil }
    }

    func testOpenRemoteVaultRecordsRemoteRecentAndStoresPassword() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentVaultsStore(defaults: defaults)
        let creds = InMemoryCredentialStore()
        let appState = AppState(recentsStore: store, credentialStore: creds)

        appState.openRemoteVault(
            host: "example.invalid", port: 22, username: "alice",
            password: "s3cret", remotePath: "/home/alice/vault")

        let identity = "sftp://alice@example.invalid:22/home/alice/vault"
        XCTAssertTrue(appState.isRemoteVault)
        XCTAssertEqual(appState.recentVaults.first?.path, identity)
        XCTAssertEqual(
            appState.recentVaults.first?.remote,
            RemoteConnection(host: "example.invalid", port: 22, username: "alice", remotePath: "/home/alice/vault"))
        XCTAssertEqual(appState.recentVaults.first?.displayName, "vault")
        XCTAssertEqual(creds.passwords[identity], "s3cret")
        // Connection details (but not the password) are persisted to the recents store.
        XCTAssertEqual(store.load().first?.remote?.host, "example.invalid")
        XCTAssertNil(store.load().first?.bookmarkData)
    }

    func testReopenRemoteRecentReconnectsWithStoredPassword() throws {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let creds = InMemoryCredentialStore()
        let identity = "sftp://u@h.invalid:22/v"
        creds.passwords[identity] = "pw"
        let store = RecentVaultsStore(defaults: defaults)
        store.save([RecentVault(
            bookmarkData: nil, displayName: "v", path: identity, lastOpened: Date(),
            remote: RemoteConnection(host: "h.invalid", port: 22, username: "u", remotePath: "/v"))])
        let appState = AppState(recentsStore: store, credentialStore: creds)

        appState.openRecent(try XCTUnwrap(appState.recentVaults.first))

        XCTAssertTrue(appState.isRemoteVault)
        XCTAssertEqual(appState.vaultDisplayName, "v")
        XCTAssertFalse(appState.isShowingRemoteConnect)
    }

    func testReopenRemoteRecentWithoutPasswordFallsBackToConnectSheet() throws {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let creds = InMemoryCredentialStore() // no stored password
        let identity = "sftp://u@h.invalid:22/v"
        let store = RecentVaultsStore(defaults: defaults)
        store.save([RecentVault(
            bookmarkData: nil, displayName: "v", path: identity, lastOpened: Date(),
            remote: RemoteConnection(host: "h.invalid", port: 22, username: "u", remotePath: "/v"))])
        let appState = AppState(recentsStore: store, credentialStore: creds)

        appState.openRecent(try XCTUnwrap(appState.recentVaults.first))

        XCTAssertFalse(appState.isRemoteVault)
        XCTAssertTrue(appState.isShowingRemoteConnect)
        // Still present — a missing password doesn't drop the recent.
        XCTAssertEqual(appState.recentVaults.count, 1)
    }

    func testAutomaticReopenRemoteRecentWithoutPasswordStaysSilent() throws {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentVaultsStore(defaults: defaults)
        store.save([RecentVault(
            bookmarkData: nil, displayName: "v", path: "sftp://u@h.invalid:22/v", lastOpened: Date(),
            remote: RemoteConnection(host: "h.invalid", port: 22, username: "u", remotePath: "/v"))])
        let appState = AppState(recentsStore: store, credentialStore: InMemoryCredentialStore())

        appState.openRecent(try XCTUnwrap(appState.recentVaults.first), isAutomatic: true)

        XCTAssertFalse(appState.isShowingRemoteConnect)
        XCTAssertFalse(appState.isRemoteVault)
    }

    func testRemoveRemoteRecentDeletesStoredPassword() throws {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let creds = InMemoryCredentialStore()
        let appState = AppState(recentsStore: RecentVaultsStore(defaults: defaults), credentialStore: creds)
        appState.openRemoteVault(host: "h.invalid", username: "u", password: "pw", remotePath: "/v")
        let identity = "sftp://u@h.invalid:22/v"
        XCTAssertEqual(creds.passwords[identity], "pw")

        appState.removeRecent(try XCTUnwrap(appState.recentVaults.first))

        XCTAssertNil(creds.passwords[identity])
        XCTAssertTrue(appState.recentVaults.isEmpty)
    }

    func testRecentVaultDecodesLegacyLocalRecordWithoutRemoteField() throws {
        // A record written before remote vaults existed: bookmarkData present, no `remote` key.
        let legacy = #"{"bookmarkData":"AAAA","displayName":"Vault","path":"/tmp/v","lastOpened":0}"#
        let recent = try JSONDecoder().decode(RecentVault.self, from: Data(legacy.utf8))

        XCTAssertFalse(recent.isRemote)
        XCTAssertNil(recent.remote)
        XCTAssertNotNil(recent.bookmarkData)
        XCTAssertEqual(recent.path, "/tmp/v")
    }
}
