@testable import HTMLGraph
import HTMLGraphCore
import XCTest

final class WebResourcePolicyTests: XCTestCase {
    func testNetworkBlockRuleBlocksRemoteSchemesButAllowsLoopback() throws {
        let port: UInt16 = 50505
        let json = WebResourcePolicy.networkBlockRuleJSON(allowingLoopbackPort: port)
        let ruleData = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: ruleData) as? [[String: Any]]
        )
        XCTAssertFalse(rules.isEmpty)

        struct Rule {
            let regex: NSRegularExpression
            let action: String
        }

        var ordered: [Rule] = []
        for rule in rules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            let action = try XCTUnwrap(rule["action"] as? [String: Any])
            let urlFilter = try XCTUnwrap(trigger["url-filter"] as? String)
            let type = try XCTUnwrap(action["type"] as? String)

            XCTAssertTrue(type == "block" || type == "ignore-previous-rules", "unexpected action: \(type)")
            // WKContentRuleList's url-filter does not support regex alternation;
            // a "|" would fail to compile and abort the page load.
            XCTAssertFalse(urlFilter.contains("|"), "url-filter must not use disjunction: \(urlFilter)")
            ordered.append(Rule(regex: try NSRegularExpression(pattern: urlFilter), action: type))
        }

        // Evaluate rules in declared order, honoring ignore-previous-rules.
        func isBlocked(_ value: String) -> Bool {
            var blocked = false
            for rule in ordered where rule.regex.matches(value) {
                switch rule.action {
                case "block": blocked = true
                case "ignore-previous-rules": blocked = false
                default: break
                }
            }
            return blocked
        }

        XCTAssertTrue(isBlocked("http://example.com/app.js"))
        XCTAssertTrue(isBlocked("https://example.com/app.js"))
        XCTAssertTrue(isBlocked("ws://example.com/socket"))
        XCTAssertTrue(isBlocked("wss://example.com/socket"))
        XCTAssertTrue(isBlocked("ftp://example.com/file.txt"))
        XCTAssertTrue(isBlocked("https://www.youtube-nocookie.com/embed/x"))

        // Our own loopback origin must stay loadable while offline.
        XCTAssertFalse(isBlocked("http://127.0.0.1:\(port)/abc/index.html"))
        XCTAssertFalse(isBlocked("http://127.0.0.1:\(port)/abc/assets/intro.mp4"))

        // A different loopback port is not our server, so it stays blocked.
        XCTAssertTrue(isBlocked("http://127.0.0.1:9999/abc/index.html"))

        // The server speaks http only; https on the same port is not our origin.
        XCTAssertTrue(isBlocked("https://127.0.0.1:\(port)/abc/index.html"))

        XCTAssertFalse(isBlocked("about:blank"))
        XCTAssertFalse(isBlocked("data:text/plain,hello"))
    }

    // MARK: - Web view identity must reflect the security policy

    // HTMLDocumentWebView applies the JS gate and the network rule list only when the
    // web view is constructed, so a policy change takes effect only by rebuilding the
    // view — which SwiftUI does when the `.id()` (this identity) changes. Trust mode and
    // network access MUST therefore be part of the identity, or a Safe<->Trusted/network
    // toggle would not apply to the live document. These tests pin that invariant.

    func testIdentityChangesWithTrustMode() {
        let safe = WebViewIdentity.make(vaultPath: "/v", contentId: "a.html", trustMode: .safe, allowsNetworkAccess: false)
        let trusted = WebViewIdentity.make(vaultPath: "/v", contentId: "a.html", trustMode: .trusted, allowsNetworkAccess: false)
        XCTAssertNotEqual(safe, trusted)
    }

    func testIdentityChangesWithNetworkAccess() {
        let off = WebViewIdentity.make(vaultPath: "/v", contentId: "a.html", trustMode: .trusted, allowsNetworkAccess: false)
        let on = WebViewIdentity.make(vaultPath: "/v", contentId: "a.html", trustMode: .trusted, allowsNetworkAccess: true)
        XCTAssertNotEqual(off, on)
    }

    func testInboxIdentityChangesWithTrustMode() {
        let safe = WebViewIdentity.make(vaultPath: "/v", contentId: "a.html", contentHash: "h", trustMode: .safe, allowsNetworkAccess: false)
        let trusted = WebViewIdentity.make(vaultPath: "/v", contentId: "a.html", contentHash: "h", trustMode: .trusted, allowsNetworkAccess: false)
        XCTAssertNotEqual(safe, trusted)
    }

    func testIdentityIsStableWhenPolicyUnchanged() {
        let a = WebViewIdentity.make(vaultPath: "/v", contentId: "a.html", trustMode: .safe, allowsNetworkAccess: false)
        let b = WebViewIdentity.make(vaultPath: "/v", contentId: "a.html", trustMode: .safe, allowsNetworkAccess: false)
        XCTAssertEqual(a, b)
    }

    func testIdentityDistinguishesContentAndVault() {
        let base = WebViewIdentity.make(vaultPath: "/v", contentId: "a.html", trustMode: .safe, allowsNetworkAccess: false)
        let otherDoc = WebViewIdentity.make(vaultPath: "/v", contentId: "b.html", trustMode: .safe, allowsNetworkAccess: false)
        let otherVault = WebViewIdentity.make(vaultPath: "/w", contentId: "a.html", trustMode: .safe, allowsNetworkAccess: false)
        XCTAssertNotEqual(base, otherDoc)
        XCTAssertNotEqual(base, otherVault)
    }
}

private extension NSRegularExpression {
    func matches(_ value: String) -> Bool {
        firstMatch(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        ) != nil
    }
}
