@testable import HTMLGraph
import XCTest

final class WebResourcePolicyTests: XCTestCase {
    func testNetworkBlockRuleCoversCommonNetworkSchemesOnly() throws {
        let ruleData = try XCTUnwrap(WebResourcePolicy.networkBlockRuleJSON.data(using: .utf8))
        let rules = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: ruleData) as? [[String: Any]]
        )
        XCTAssertFalse(rules.isEmpty)

        var regexes: [NSRegularExpression] = []
        for rule in rules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            let action = try XCTUnwrap(rule["action"] as? [String: Any])
            let urlFilter = try XCTUnwrap(trigger["url-filter"] as? String)

            XCTAssertEqual(action["type"] as? String, "block")
            // WKContentRuleList's url-filter does not support regex alternation;
            // a "|" would fail to compile and abort the page load.
            XCTAssertFalse(urlFilter.contains("|"), "url-filter must not use disjunction: \(urlFilter)")
            regexes.append(try NSRegularExpression(pattern: urlFilter))
        }

        func isBlocked(_ value: String) -> Bool {
            regexes.contains { $0.matches(value) }
        }

        XCTAssertTrue(isBlocked("http://example.com/app.js"))
        XCTAssertTrue(isBlocked("https://example.com/app.js"))
        XCTAssertTrue(isBlocked("ws://example.com/socket"))
        XCTAssertTrue(isBlocked("wss://example.com/socket"))
        XCTAssertTrue(isBlocked("ftp://example.com/file.txt"))

        XCTAssertFalse(isBlocked("htmlgraph://vault/index.html"))
        XCTAssertFalse(isBlocked("file:///tmp/vault/index.html"))
        XCTAssertFalse(isBlocked("about:blank"))
        XCTAssertFalse(isBlocked("data:text/plain,hello"))
        XCTAssertFalse(isBlocked("blob:https://example.com/id"))
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
