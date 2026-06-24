import XCTest
@testable import HTMLGraphCore

/// Pure-construction tests for `SFTPFileSystem` — identity formatting and the local-only
/// affordance. No network: constructing the value (and reading `vaultIdentity`/`absolutePath`)
/// never opens a connection (that happens lazily on the first I/O call). Full SFTP behavior is
/// exercised by manual integration tests against a real `sshd`.
final class SFTPFileSystemTests: XCTestCase {
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
}
