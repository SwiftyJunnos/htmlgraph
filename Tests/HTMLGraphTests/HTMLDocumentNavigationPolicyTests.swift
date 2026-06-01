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

        XCTAssertEqual(policy.decision(for: url, isMainFrame: true), .external(url))
    }

    func testKnownInternalDocumentSelectsDocument() {
        let policy = makePolicy()
        let url = vaultURL.appendingPathComponent("notes/graph.html")

        XCTAssertEqual(policy.decision(for: url, isMainFrame: true), .internalDocument("notes/graph.html"))
    }

    func testUnknownInternalAssetReturnsError() {
        let policy = makePolicy()
        let url = vaultURL.appendingPathComponent("assets/logo.svg")

        guard case .error(let message) = policy.decision(for: url, isMainFrame: true) else {
            return XCTFail("Expected error for unknown internal asset")
        }
        XCTAssertTrue(message.contains("assets/logo.svg"))
    }

    func testSameDocumentFragmentAllowsNavigation() {
        let policy = makePolicy()

        XCTAssertEqual(
            policy.decision(for: URL(string: "file:///tmp/vault/index.html#section")!, isMainFrame: true),
            .allow
        )
        XCTAssertEqual(
            policy.decision(for: URL(string: "file:///tmp/vault/index.html#other")!, isMainFrame: true),
            .allow
        )
    }

    func testExternalURLReturnsExternal() {
        let policy = makePolicy()
        let url = URL(string: "https://example.com")!

        XCTAssertEqual(policy.decision(for: url, isMainFrame: true), .external(url))
    }

    func testMainFrameExternalNavigationIsCanceledAsExternal() {
        let policy = makePolicy()
        let url = URL(string: "https://example.com/redirect")!

        XCTAssertEqual(policy.decision(for: url, isMainFrame: true), .external(url))
    }

    private func makePolicy() -> HTMLDocumentNavigationPolicy {
        HTMLDocumentNavigationPolicy(
            currentDocumentURL: vaultURL.appendingPathComponent("index.html"),
            vaultURL: vaultURL,
            knownDocumentIds: knownDocumentIds
        )
    }
}
