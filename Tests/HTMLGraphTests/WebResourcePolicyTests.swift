@testable import HTMLGraph
import XCTest

final class WebResourcePolicyTests: XCTestCase {
    func testNetworkBlockRuleCoversCommonNetworkSchemesOnly() throws {
        let ruleData = try XCTUnwrap(WebResourcePolicy.networkBlockRuleJSON.data(using: .utf8))
        let rules = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: ruleData) as? [[String: Any]]
        )
        let firstRule = try XCTUnwrap(rules.first)
        let trigger = try XCTUnwrap(firstRule["trigger"] as? [String: Any])
        let action = try XCTUnwrap(firstRule["action"] as? [String: Any])
        let urlFilter = try XCTUnwrap(trigger["url-filter"] as? String)

        XCTAssertEqual(action["type"] as? String, "block")

        let regex = try NSRegularExpression(pattern: urlFilter)
        XCTAssertTrue(regex.matches("http://example.com/app.js"))
        XCTAssertTrue(regex.matches("https://example.com/app.js"))
        XCTAssertTrue(regex.matches("ws://example.com/socket"))
        XCTAssertTrue(regex.matches("wss://example.com/socket"))
        XCTAssertTrue(regex.matches("ftp://example.com/file.txt"))

        XCTAssertFalse(regex.matches("htmlgraph://vault/index.html"))
        XCTAssertFalse(regex.matches("file:///tmp/vault/index.html"))
        XCTAssertFalse(regex.matches("about:blank"))
        XCTAssertFalse(regex.matches("data:text/plain,hello"))
        XCTAssertFalse(regex.matches("blob:https://example.com/id"))
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
