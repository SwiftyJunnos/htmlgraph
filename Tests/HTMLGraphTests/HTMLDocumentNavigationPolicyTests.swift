import Foundation
@testable import HTMLGraph
import XCTest

final class HTMLDocumentNavigationPolicyTests: XCTestCase {
    private let vaultURL = URL(fileURLWithPath: "/tmp/vault", isDirectory: true)
    private let knownDocumentIds: Set<String> = [
        "index.html",
        "notes/graph.html"
    ]

    func testPathPrefixSiblingIsNotInsideVault() {
        let policy = makePolicy()
        let url = URL(fileURLWithPath: "/tmp/vault2/index.html")

        XCTAssertEqual(policy.decision(for: url, isMainFrame: true, isUserInitiated: true), .external(url))
    }

    func testKnownInternalDocumentSelectsDocument() {
        let policy = makePolicy()
        let url = vaultURL.appendingPathComponent("notes/graph.html")

        XCTAssertEqual(
            policy.decision(for: url, isMainFrame: true, isUserInitiated: true),
            .internalDocument("notes/graph.html")
        )
    }

    func testUnknownInternalAssetReturnsError() {
        let policy = makePolicy()
        let url = vaultURL.appendingPathComponent("assets/logo.svg")

        guard case .error(let message) = policy.decision(for: url, isMainFrame: true, isUserInitiated: true) else {
            return XCTFail("Expected error for unknown internal asset")
        }
        XCTAssertTrue(message.contains("assets/logo.svg"))
    }

    func testSameDocumentFragmentAllowsNavigation() {
        let policy = makePolicy()

        XCTAssertEqual(
            policy.decision(
                for: URL(string: "file:///tmp/vault/index.html#section")!,
                isMainFrame: true,
                isUserInitiated: true
            ),
            .allow
        )
        XCTAssertEqual(
            policy.decision(
                for: URL(string: "file:///tmp/vault/index.html#other")!,
                isMainFrame: true,
                isUserInitiated: false
            ),
            .allow
        )
    }

    func testUserInitiatedExternalURLReturnsExternal() {
        let policy = makePolicy()
        let url = URL(string: "https://example.com")!

        XCTAssertEqual(policy.decision(for: url, isMainFrame: true, isUserInitiated: true), .external(url))
    }

    func testNonUserInitiatedExternalNavigationReturnsError() {
        let policy = makePolicy()
        let url = URL(string: "https://example.com/redirect")!

        guard case .error(let message) = policy.decision(
            for: url,
            isMainFrame: true,
            isUserInitiated: false
        ) else {
            return XCTFail("Expected error for non-user-initiated external navigation")
        }
        XCTAssertTrue(message.contains("https://example.com/redirect"))
    }

    func testNonMainFrameNetworkNavigationReturnsNetworkBlockedWhenNetworkOff() {
        let policy = makePolicy()
        let url = URL(string: "https://example.com/frame.html")!

        XCTAssertEqual(
            policy.decision(for: url, isMainFrame: false, isUserInitiated: false),
            .networkBlocked(url)
        )
    }

    func testAboutBlankSubframeIsAllowed() {
        let policy = makePolicy()
        let url = URL(string: "about:blank")!

        XCTAssertEqual(
            policy.decision(for: url, isMainFrame: false, isUserInitiated: false),
            .allow
        )
    }

    func testAboutBlankMainFrameIsAllowed() {
        let policy = makePolicy()
        let url = URL(string: "about:blank")!

        XCTAssertEqual(
            policy.decision(for: url, isMainFrame: true, isUserInitiated: false),
            .allow
        )
    }

    func testAboutSrcdocSubframeIsAllowed() {
        let policy = makePolicy()
        let url = URL(string: "about:srcdoc")!

        XCTAssertEqual(
            policy.decision(for: url, isMainFrame: false, isUserInitiated: false),
            .allow
        )
    }

    func testAboutSrcdocImpostorIsNotAllowed() {
        let policy = makePolicy()
        let url = URL(string: "about:srcdocEVIL")!

        XCTAssertNotEqual(
            policy.decision(for: url, isMainFrame: false, isUserInitiated: false),
            .allow
        )
    }

    func testNonMainFrameVaultFileAllowsNavigation() {
        let policy = makePolicy()
        let url = vaultURL.appendingPathComponent("embedded.html")

        XCTAssertEqual(
            policy.decision(for: url, isMainFrame: false, isUserInitiated: false),
            .allow
        )
    }

    func testNonMainFrameFileOutsideVaultReturnsError() {
        let policy = makePolicy()
        let url = URL(fileURLWithPath: "/tmp/secret.html")

        guard case .error(let message) = policy.decision(
            for: url,
            isMainFrame: false,
            isUserInitiated: false
        ) else {
            return XCTFail("Expected error for outside-vault subframe navigation")
        }
        XCTAssertTrue(message.contains("secret.html"))
    }

    func testNonMainFrameNetworkEmbedAllowedWhenNetworkAccessEnabled() {
        let policy = makePolicy(allowsNetworkAccess: true)
        let url = URL(string: "https://www.youtube-nocookie.com/embed/aqz-KE-bpKQ")!

        XCTAssertEqual(
            policy.decision(for: url, isMainFrame: false, isUserInitiated: false),
            .allow
        )
    }

    func testNonMainFrameNetworkEmbedBlockedWhenNetworkAccessDisabled() {
        let policy = makePolicy(allowsNetworkAccess: false)
        let url = URL(string: "https://www.youtube-nocookie.com/embed/aqz-KE-bpKQ")!

        XCTAssertEqual(
            policy.decision(for: url, isMainFrame: false, isUserInitiated: false),
            .networkBlocked(url)
        )
    }

    private func makePolicy(allowsNetworkAccess: Bool = false) -> HTMLDocumentNavigationPolicy {
        HTMLDocumentNavigationPolicy(
            currentDocumentURL: vaultURL.appendingPathComponent("index.html"),
            vaultURL: vaultURL,
            knownDocumentIds: knownDocumentIds,
            allowsNetworkAccess: allowsNetworkAccess
        )
    }
}
