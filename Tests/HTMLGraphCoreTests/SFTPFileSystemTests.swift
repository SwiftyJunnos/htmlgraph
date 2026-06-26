import XCTest
@testable import HTMLGraphCore

/// Pure-construction tests for `SFTPFileSystem` — identity formatting and the local-only
/// affordance. No network: constructing the value (and reading `vaultIdentity`/`absolutePath`)
/// never opens a connection (that happens lazily on the first I/O call). Full SFTP behavior is
/// exercised by manual integration tests against a real `sshd`.
final class SFTPFileSystemTests: XCTestCase {
    enum TestError: Error {
        case staleConnection
    }

    func testVaultIdentityFormatsAsSFTPURL() {
        let fs = SFTPFileSystem(
            host: "example.com", port: 22, username: "alice",
            credential: .password("pw"), remotePath: "/home/alice/vault")
        XCTAssertEqual(fs.vaultIdentity, "sftp://alice@example.com:22/home/alice/vault")
    }

    func testVaultIdentityNormalizesTrailingSlash() {
        let fs = SFTPFileSystem(
            host: "h", port: 2222, username: "u",
            credential: .password("p"), remotePath: "/srv/vault/")
        XCTAssertEqual(fs.vaultIdentity, "sftp://u@h:2222/srv/vault")
    }

    func testAbsolutePathIsNilForRemote() {
        let fs = SFTPFileSystem(
            host: "h", username: "u", credential: .password("p"), remotePath: "/v")
        XCTAssertNil(fs.absolutePath(for: "notes/page.html"))
    }

    func testDisplayNameAndSubtitleForRemoteVault() {
        let fs = SFTPFileSystem(
            host: "example.com", port: 22, username: "alice",
            credential: .password("pw"), remotePath: "/home/alice/vault")
        XCTAssertEqual(fs.displayName, "vault")
        // The default SSH port is omitted from the subtitle.
        XCTAssertEqual(fs.displaySubtitle, "alice@example.com:/home/alice/vault")
    }

    func testDisplaySubtitleIncludesNonDefaultPort() {
        let fs = SFTPFileSystem(
            host: "h", port: 2222, username: "u",
            credential: .password("p"), remotePath: "/srv/notes")
        XCTAssertEqual(fs.displayName, "notes")
        XCTAssertEqual(fs.displaySubtitle, "u@h:2222:/srv/notes")
    }

    func testDisplayNameFallsBackToHostForRootVault() {
        let fs = SFTPFileSystem(
            host: "example.com", username: "u", credential: .password("p"), remotePath: "/")
        XCTAssertEqual(fs.displayName, "example.com")
        XCTAssertEqual(fs.displaySubtitle, "u@example.com:/")
    }

    func testRetryPolicyInvalidatesFailedClientAndRetriesOnce() async throws {
        var nextClient = 0
        var attempts: [Int] = []
        var invalidated: [Int] = []

        let result = try await SFTPConnectionRetryPolicy.run(
            retryingAfterFailure: true,
            client: {
                nextClient += 1
                return nextClient
            },
            invalidate: { invalidated.append($0) },
            operation: { client in
                attempts.append(client)
                if client == 1 { throw TestError.staleConnection }
                return "read from \(client)"
            }
        )

        XCTAssertEqual(result, "read from 2")
        XCTAssertEqual(attempts, [1, 2])
        XCTAssertEqual(invalidated, [1])
    }

    func testRetryPolicyInvalidatesWithoutRetryForMutations() async throws {
        var clients = [1]
        var invalidated: [Int] = []

        do {
            _ = try await SFTPConnectionRetryPolicy.run(
                retryingAfterFailure: false,
                client: { clients.removeFirst() },
                invalidate: { invalidated.append($0) },
                operation: { _ in throw TestError.staleConnection }
            ) as String
            XCTFail("Expected the mutation failure to be rethrown.")
        } catch TestError.staleConnection {
            XCTAssertTrue(clients.isEmpty)
            XCTAssertEqual(invalidated, [1])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
