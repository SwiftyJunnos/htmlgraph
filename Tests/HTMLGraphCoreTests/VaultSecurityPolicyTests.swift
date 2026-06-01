import XCTest
@testable import HTMLGraphCore

final class VaultSecurityPolicyTests: XCTestCase {
    func testSafeModeBlocksNetworkAndJavascriptByDefault() {
        let policy = VaultSecurityPolicy(mode: .safe, allowsNetworkAccess: false)

        XCTAssertFalse(policy.allowsJavaScript)
        XCTAssertFalse(policy.allows(URL(string: "https://example.com/app.js")!, vaultRoot: URL(fileURLWithPath: "/vault")))
        XCTAssertTrue(policy.allows(URL(fileURLWithPath: "/vault/assets/style.css"), vaultRoot: URL(fileURLWithPath: "/vault")))
        XCTAssertFalse(policy.allows(URL(fileURLWithPath: "/private/secret.txt"), vaultRoot: URL(fileURLWithPath: "/vault")))
    }

    func testTrustedModeAllowsJavaScriptButNetworkIsSeparate() {
        let policy = VaultSecurityPolicy(mode: .trusted, allowsNetworkAccess: false)

        XCTAssertTrue(policy.allowsJavaScript)
        XCTAssertFalse(policy.allows(URL(string: "https://example.com/app.js")!, vaultRoot: URL(fileURLWithPath: "/vault")))
    }

    func testDeniesFilePathPrefixSibling() {
        let policy = VaultSecurityPolicy(mode: .safe, allowsNetworkAccess: false)

        XCTAssertFalse(policy.allows(URL(fileURLWithPath: "/vault2/file.css"), vaultRoot: URL(fileURLWithPath: "/vault")))
    }

    func testNetworkSchemesRequireNetworkAccess() {
        let blockedPolicy = VaultSecurityPolicy(mode: .trusted, allowsNetworkAccess: false)
        let allowedPolicy = VaultSecurityPolicy(mode: .trusted, allowsNetworkAccess: true)

        XCTAssertFalse(blockedPolicy.allows(URL(string: "http://example.com/app.js")!, vaultRoot: URL(fileURLWithPath: "/vault")))
        XCTAssertFalse(blockedPolicy.allows(URL(string: "https://example.com/app.js")!, vaultRoot: URL(fileURLWithPath: "/vault")))
        XCTAssertTrue(allowedPolicy.allows(URL(string: "http://example.com/app.js")!, vaultRoot: URL(fileURLWithPath: "/vault")))
        XCTAssertTrue(allowedPolicy.allows(URL(string: "https://example.com/app.js")!, vaultRoot: URL(fileURLWithPath: "/vault")))
    }

    func testUnsafeSchemesAreDeniedEvenWithNetworkAccess() {
        let policy = VaultSecurityPolicy(mode: .trusted, allowsNetworkAccess: true)
        let vaultRoot = URL(fileURLWithPath: "/vault")

        XCTAssertFalse(policy.allows(URL(string: "data:text/css,body{}")!, vaultRoot: vaultRoot))
        XCTAssertFalse(policy.allows(URL(string: "javascript:alert(1)")!, vaultRoot: vaultRoot))
        XCTAssertFalse(policy.allows(URL(string: "htmlgraph://resource")!, vaultRoot: vaultRoot))
    }

    func testDeniesSymlinkEscapeOutsideVaultRoot() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLGraphTests-\(UUID().uuidString)", isDirectory: true)
        let vaultRoot = tempRoot.appendingPathComponent("vault", isDirectory: true)
        let outsideRoot = tempRoot.appendingPathComponent("outside", isDirectory: true)
        let outsideFile = outsideRoot.appendingPathComponent("secret.css")
        let symlinkURL = vaultRoot.appendingPathComponent("linked-secret.css")
        let policy = VaultSecurityPolicy(mode: .safe, allowsNetworkAccess: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try "body {}".write(to: outsideFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFile)

        XCTAssertFalse(policy.allows(symlinkURL, vaultRoot: vaultRoot))
    }
}
