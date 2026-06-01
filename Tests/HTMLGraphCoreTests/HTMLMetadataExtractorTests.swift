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
}
