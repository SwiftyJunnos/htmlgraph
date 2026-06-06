import XCTest
@testable import HTMLGraphCore

final class EmbeddingInputTests: XCTestCase {
    func testCombinedTextPrependsTitleOnItsOwnLine() {
        XCTAssertEqual(
            EmbeddingInput.combinedText(title: "회의록", bodyText: "다음 분기 일정을 논의했다."),
            "회의록\n다음 분기 일정을 논의했다."
        )
    }

    func testCombinedTextHandlesEmptyParts() {
        XCTAssertEqual(EmbeddingInput.combinedText(title: "T", bodyText: ""), "T")
        XCTAssertEqual(EmbeddingInput.combinedText(title: "", bodyText: "B"), "B")
        XCTAssertEqual(EmbeddingInput.combinedText(title: "  ", bodyText: "  "), "")
    }

    func testShortDocumentIsASingleChunk() {
        let chunks = EmbeddingInput.chunks(title: "T", bodyText: "short body")
        XCTAssertEqual(chunks, ["T\nshort body"])
    }

    func testEmptyDocumentProducesNoChunks() {
        XCTAssertEqual(EmbeddingInput.chunks(title: "", bodyText: ""), [])
    }

    func testLongDocumentSplitsIntoMultipleChunks() {
        let body = String(repeating: "word ", count: 600) // ~3000 chars
        let chunks = EmbeddingInput.chunks(title: "T", bodyText: body, maxCharsPerChunk: 1000)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 1000)
        }
    }

    func testChunkingPrefersWhitespaceBoundaries() {
        // Three 30-char words separated by spaces; cap 35 forces one word per chunk.
        let words = ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                     "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                     "cccccccccccccccccccccccccccccc"]
        let chunks = EmbeddingInput.chunks(title: "", bodyText: words.joined(separator: " "), maxCharsPerChunk: 35)
        XCTAssertEqual(chunks, words)
    }

    func testHardSplitsWhenNoWhitespaceFits() {
        let body = String(repeating: "x", count: 50) // no spaces
        let chunks = EmbeddingInput.chunks(title: "", bodyText: body, maxCharsPerChunk: 20)
        XCTAssertEqual(chunks.count, 3) // 20 + 20 + 10
        XCTAssertEqual(chunks.map(\.count), [20, 20, 10])
    }
}
