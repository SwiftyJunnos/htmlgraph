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
}
