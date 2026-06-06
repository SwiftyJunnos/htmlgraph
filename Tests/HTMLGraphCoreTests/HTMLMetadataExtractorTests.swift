import XCTest
@testable import HTMLGraphCore

final class HTMLMetadataExtractorTests: XCTestCase {
    func testTitleUsesTitleBeforeH1BeforeFilename() throws {
        let extractor = HTMLMetadataExtractor()

        XCTAssertEqual(
            try extractor.title(from: "<html><head><title>Title Tag</title></head><body><h1>Heading</h1></body></html>", fallbackFilename: "file.html"),
            "Title Tag"
        )
        XCTAssertEqual(
            try extractor.title(from: "<html><body><h1>Heading</h1></body></html>", fallbackFilename: "file.html"),
            "Heading"
        )
        XCTAssertEqual(
            try extractor.title(from: "<html><body><p>No title</p></body></html>", fallbackFilename: "file.html"),
            "file"
        )
    }

    func testExtractsLinksWithHrefAndText() throws {
        let extractor = HTMLMetadataExtractor()
        let links = try extractor.links(from: """
        <html><body>
          <a href="./notes/graph.html">Graph note</a>
          <a href="https://example.com">External</a>
        </body></html>
        """)

        XCTAssertEqual(links.map(\.href), ["./notes/graph.html", "https://example.com"])
        XCTAssertEqual(links.map(\.text), ["Graph note", "External"])
    }

    // MARK: - bodyText

    func testBodyTextStripsTagsAndCollapsesWhitespace() throws {
        let extractor = HTMLMetadataExtractor()
        let text = try extractor.bodyText(from: """
        <html><body>
          <h1>제목</h1>
          <p>첫째   문단.</p>
          <p>둘째 문단.</p>
        </body></html>
        """)
        XCTAssertEqual(text, "제목 첫째 문단. 둘째 문단.")
    }

    func testBodyTextRemovesScriptAndStyleContents() throws {
        let extractor = HTMLMetadataExtractor()
        let text = try extractor.bodyText(from: """
        <html><body>
          <style>.x { color: red; }</style>
          <p>보이는 텍스트</p>
          <script>console.log("hidden");</script>
        </body></html>
        """)
        XCTAssertEqual(text, "보이는 텍스트")
    }

    func testBodyTextMissingBodyIsEmpty() throws {
        let extractor = HTMLMetadataExtractor()
        // No body element at all.
        XCTAssertEqual(try extractor.bodyText(from: "<html><head><title>T</title></head></html>"), "")
    }

    func testBodyTextRespectsMaxChars() throws {
        let extractor = HTMLMetadataExtractor()
        let body = String(repeating: "가", count: 5000)
        let text = try extractor.bodyText(from: "<html><body>\(body)</body></html>", maxChars: 100)
        XCTAssertEqual(text.count, 100)
    }
}
