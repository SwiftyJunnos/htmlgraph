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
}
