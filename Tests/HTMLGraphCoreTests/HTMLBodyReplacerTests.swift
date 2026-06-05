import XCTest
@testable import HTMLGraphCore

final class HTMLBodyReplacerTests: XCTestCase {
    // MARK: - Happy path

    func testReplacesBodyInnerPreservingDoctypeHeadAndBodyAttributes() {
        let original = """
        <!DOCTYPE html>
        <html lang="ko">
          <head><title>회의록</title><script>setup();</script></head>
          <body class="note" data-id="42"><p>old</p></body>
        </html>
        """
        let result = HTMLBodyReplacer.replacingBodyInner(of: original, with: "<p>new</p>")
        XCTAssertEqual(result, """
        <!DOCTYPE html>
        <html lang="ko">
          <head><title>회의록</title><script>setup();</script></head>
          <body class="note" data-id="42"><p>new</p></body>
        </html>
        """)
    }

    func testPreservesEverythingOutsideBodyByteForByte() {
        let original = "<!DOCTYPE html>\n<html>\n<head>\n  <meta charset='utf-8'>\n</head>\n<body>\n  <h1>hi</h1>\n</body>\n</html>\n"
        let result = HTMLBodyReplacer.replacingBodyInner(of: original, with: "X")
        XCTAssertEqual(result, "<!DOCTYPE html>\n<html>\n<head>\n  <meta charset='utf-8'>\n</head>\n<body>X</body>\n</html>\n")
    }

    func testCaseInsensitiveBodyTags() {
        let original = "<HTML><BODY>old</BODY></HTML>"
        XCTAssertEqual(HTMLBodyReplacer.replacingBodyInner(of: original, with: "new"), "<HTML><BODY>new</BODY></HTML>")
    }

    func testBodyTagWithAttributeContainingAngleBracket() {
        let original = #"<body data-tpl="a>b"><p>old</p></body>"#
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "<p>new</p>"),
            #"<body data-tpl="a>b"><p>new</p></body>"#
        )
    }

    func testEmptyNewInnerEmptiesBody() {
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: "<html><body><p>x</p></body></html>", with: ""),
            "<html><body></body></html>"
        )
    }

    // MARK: - Robustness against `<body>` literals that are NOT the body tag

    func testIgnoresBodyLiteralInsideHeadComment() {
        // A `<body>` mention inside a head comment must not be taken as the open tag.
        let original = "<html><head><!-- the <body> region follows --></head><body><p>old</p></body></html>"
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "<p>new</p>"),
            "<html><head><!-- the <body> region follows --></head><body><p>new</p></body></html>"
        )
    }

    func testIgnoresBodyLiteralInsideHeadScript() {
        let original = "<head><meta charset=\"utf-8\"><script>var x = document.body; // <body>\n</script></head><body><h1>T</h1></body></html>"
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "<p>E</p>"),
            "<head><meta charset=\"utf-8\"><script>var x = document.body; // <body>\n</script></head><body><p>E</p></body></html>"
        )
    }

    func testIgnoresBodyLiteralInsideTitle() {
        let original = "<html><head><title>about <body> tags</title></head><body>old</body></html>"
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "new"),
            "<html><head><title>about <body> tags</title></head><body>new</body></html>"
        )
    }

    func testIgnoresBodyLiteralInsideStyle() {
        let original = "<head><style>/* <body> */ .a{color:red}</style></head><body>old</body></html>"
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "new"),
            "<head><style>/* <body> */ .a{color:red}</style></head><body>new</body></html>"
        )
    }

    func testUppercaseScriptIsSkipped() {
        let original = "<head><SCRIPT>// <body></SCRIPT></head><body>old</body></html>"
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "new"),
            "<head><SCRIPT>// <body></SCRIPT></head><body>new</body></html>"
        )
    }

    // MARK: - Close-tag selection

    func testUsesFirstRealCloseIgnoringTrailingCommentClose() {
        // A literal </body> in a trailing comment, AFTER the real one, must not win.
        let original = "<html><body>v1</body><!-- archived: </body> --></html>"
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "v2"),
            "<html><body>v2</body><!-- archived: </body> --></html>"
        )
    }

    func testIgnoresEscapedBodyCloseInContent() {
        let original = "<body><pre>&lt;/body&gt; sample</pre></body>"
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "Z"),
            "<body>Z</body>"
        )
    }

    func testIgnoresBodyCloseInsideTrailingScript() {
        let original = "<body>v1</body><script>var s = '</body>';</script></html>"
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "v2"),
            "<body>v2</body><script>var s = '</body>';</script></html>"
        )
    }

    func testIgnoresBodyCloseInsideCDATA() {
        // A </body> inside a CDATA-like section must not be taken as the real close; the body
        // inner (old + cdata + more) is fully replaced, preserving the outer document.
        let original = "<html><body>old<![CDATA[ </body> ]]>more</body></html>"
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "NEW"),
            "<html><body>NEW</body></html>"
        )
    }

    func testCDATAWithEarlyAngleBracketDoesNotExposeFakeBody() {
        // CDATA (foreign content) ends at ]]>, not the first '>'. A '>' inside the CDATA before
        // a `<body>` literal must NOT close the section early and expose that fake open tag.
        let original = "<svg><![CDATA[a > b <body>x]]></svg><html><body>REAL</body></html>"
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "NEW"),
            "<svg><![CDATA[a > b <body>x]]></svg><html><body>NEW</body></html>"
        )
    }

    func testIgnoresBodyLiteralInsideAnotherTagsAttribute() {
        // <body> embedded in another element's attribute value is not a tag.
        let original = #"<html><head><meta data-tpl="<body>"></head><body>old</body></html>"#
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "new"),
            #"<html><head><meta data-tpl="<body>"></head><body>new</body></html>"#
        )
    }

    func testIgnoresBodyCloseInsideAnotherTagsAttribute() {
        let original = #"<body><a title="</body>">x</a></body></html>"#
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "Z"),
            #"<body>Z</body></html>"#
        )
    }

    func testIgnoresBodyLiteralInsideProcessingInstruction() {
        let original = "<?xml-stylesheet href=\"<body>\"?><html><body>old</body></html>"
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "new"),
            "<?xml-stylesheet href=\"<body>\"?><html><body>new</body></html>"
        )
    }

    func testEmojiOffsetsRoundTripByGraphemeCluster() {
        let original = "<html><head>🙂</head><body>🎉old</body></html>"
        XCTAssertEqual(
            HTMLBodyReplacer.replacingBodyInner(of: original, with: "✅new"),
            "<html><head>🙂</head><body>✅new</body></html>"
        )
    }

    // MARK: - Cases that must return nil (caller falls back non-destructively)

    func testReturnsNilForImplicitBodyFullDocument() {
        // Valid HTML with an IMPLIED body (no literal <body> tag). Must NOT be spliced — the
        // caller falls back to a full-document write so the head/doctype aren't destroyed.
        XCTAssertNil(HTMLBodyReplacer.replacingBodyInner(
            of: "<!DOCTYPE html><html><head><title>T</title></head><p>x</p></html>",
            with: "<p>new</p>"
        ))
    }

    func testReturnsNilWhenCloseTagMissing() {
        XCTAssertNil(HTMLBodyReplacer.replacingBodyInner(of: "<html><body><p>no close", with: "x"))
    }

    func testReturnsNilForFragmentWithoutBody() {
        XCTAssertNil(HTMLBodyReplacer.replacingBodyInner(of: "<h1>just a fragment</h1>", with: "x"))
    }

    func testReturnsNilWhenOnlyBodyLiteralIsInComment() {
        XCTAssertNil(HTMLBodyReplacer.replacingBodyInner(of: "<html><!-- <body>x</body> --></html>", with: "y"))
    }

    func testDoesNotMatchBodylikeTag() {
        XCTAssertNil(HTMLBodyReplacer.replacingBodyInner(of: "<bodyguard>nope</bodyguard>", with: "x"))
    }
}
