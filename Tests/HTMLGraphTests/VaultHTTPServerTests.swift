@testable import HTMLGraph
import XCTest

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class VaultHTTPServerTests: XCTestCase {
    private var vaultURL: URL!
    private let token = "testtoken123"
    private let binBytes = Data((0..<256).map { UInt8($0) })

    override func setUpWithError() throws {
        try super.setUpWithError()
        vaultURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VaultHTTPServerTests-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: vaultURL.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try fm.createDirectory(at: vaultURL.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try "<h1>Hi</h1>".write(to: vaultURL.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "<p>page</p>".write(to: vaultURL.appendingPathComponent("notes/page.html"), atomically: true, encoding: .utf8)
        try binBytes.write(to: vaultURL.appendingPathComponent("assets/data.bin"))
    }

    override func tearDownWithError() throws {
        if let vaultURL { try? FileManager.default.removeItem(at: vaultURL) }
        try super.tearDownWithError()
    }

    private func makeResponder() -> VaultHTTPResponder {
        VaultHTTPResponder(vaultURL: vaultURL, token: token)
    }

    // MARK: - Responder

    func testGetServesFileWithMimeAndBody() async {
        let response = await makeResponder().respond(method: "GET", target: "/\(token)/index.html", rangeHeader: nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headerValue("Content-Type"), "text/html")
        XCTAssertEqual(response.headerValue("Accept-Ranges"), "bytes")
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "<h1>Hi</h1>")
    }

    func testHeadOmitsBodyButReportsFullLength() async {
        let response = await makeResponder().respond(method: "HEAD", target: "/\(token)/index.html", rangeHeader: nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertEqual(response.headerValue("Content-Length"), "11")
    }

    func testWrongTokenIsForbidden() async {
        let response = await makeResponder().respond(method: "GET", target: "/wrongtoken/index.html", rangeHeader: nil)
        XCTAssertEqual(response.status, 403)
    }

    func testPathTraversalIsForbidden() async {
        let response = await makeResponder().respond(method: "GET", target: "/\(token)/../../etc/passwd", rangeHeader: nil)
        XCTAssertEqual(response.status, 403)
    }

    func testMissingFileIsNotFound() async {
        let response = await makeResponder().respond(method: "GET", target: "/\(token)/nope.html", rangeHeader: nil)
        XCTAssertEqual(response.status, 404)
    }

    func testUnsupportedMethodIsNotAllowed() async {
        let response = await makeResponder().respond(method: "POST", target: "/\(token)/index.html", rangeHeader: nil)
        XCTAssertEqual(response.status, 405)
        XCTAssertEqual(response.headerValue("Allow"), "GET, HEAD")
    }

    func testQueryAndFragmentAreStripped() async {
        let response = await makeResponder().respond(method: "GET", target: "/\(token)/index.html?v=1#top", rangeHeader: nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "<h1>Hi</h1>")
    }

    func testByteRangeReturnsPartialContent() async {
        let response = await makeResponder().respond(method: "GET", target: "/\(token)/assets/data.bin", rangeHeader: "bytes=0-3")
        XCTAssertEqual(response.status, 206)
        XCTAssertEqual(response.headerValue("Content-Range"), "bytes 0-3/256")
        XCTAssertEqual(response.headerValue("Content-Length"), "4")
        XCTAssertEqual(response.body, binBytes.subdata(in: 0..<4))
    }

    func testSuffixByteRange() async {
        let response = await makeResponder().respond(method: "GET", target: "/\(token)/assets/data.bin", rangeHeader: "bytes=-2")
        XCTAssertEqual(response.status, 206)
        XCTAssertEqual(response.headerValue("Content-Range"), "bytes 254-255/256")
        XCTAssertEqual(response.body, binBytes.subdata(in: 254..<256))
    }

    func testUnsatisfiableRangeIs416() async {
        let response = await makeResponder().respond(method: "GET", target: "/\(token)/assets/data.bin", rangeHeader: "bytes=999-")
        XCTAssertEqual(response.status, 416)
        XCTAssertEqual(response.headerValue("Content-Range"), "bytes */256")
    }

    func testParseByteRangeVariants() {
        XCTAssertEqual(VaultHTTPResponder.parseByteRange("bytes=0-3", totalLength: 256), 0..<4)
        XCTAssertEqual(VaultHTTPResponder.parseByteRange("bytes=10-", totalLength: 256), 10..<256)
        XCTAssertEqual(VaultHTTPResponder.parseByteRange("bytes=-5", totalLength: 256), 251..<256)
        XCTAssertEqual(VaultHTTPResponder.parseByteRange("bytes=200-9999", totalLength: 256), 200..<256)
        XCTAssertNil(VaultHTTPResponder.parseByteRange("bytes=300-400", totalLength: 256))
        XCTAssertNil(VaultHTTPResponder.parseByteRange("bytes=0-3,8-9", totalLength: 256))
        XCTAssertNil(VaultHTTPResponder.parseByteRange("items=0-3", totalLength: 256))
    }

    // MARK: - URL mapping

    func testResourceURLAndReverseMappingRoundTrip() throws {
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:50505/\(token)/"))
        let fileURL = vaultURL.appendingPathComponent("notes/page.html")

        let resourceURL = try XCTUnwrap(
            VaultHTTPServer.resourceURL(forFileAt: fileURL, baseURL: baseURL, vaultURL: vaultURL)
        )
        XCTAssertEqual(resourceURL.absoluteString, "http://127.0.0.1:50505/\(token)/notes/page.html")

        let mappedBack = try XCTUnwrap(
            VaultHTTPServer.fileURL(forLoopback: resourceURL, baseURL: baseURL, vaultURL: vaultURL)
        )
        XCTAssertEqual(mappedBack.standardizedFileURL, fileURL.standardizedFileURL)
    }

    func testResourceURLRejectsFilesOutsideVault() {
        let baseURL = URL(string: "http://127.0.0.1:50505/\(token)/")!
        XCTAssertNil(
            VaultHTTPServer.resourceURL(
                forFileAt: URL(fileURLWithPath: "/etc/passwd"),
                baseURL: baseURL,
                vaultURL: vaultURL
            )
        )
    }

    func testLoopbackMappingRejectsWrongPort() {
        let baseURL = URL(string: "http://127.0.0.1:50505/\(token)/")!
        let foreign = URL(string: "http://127.0.0.1:1/\(token)/index.html")!
        XCTAssertNil(VaultHTTPServer.fileURL(forLoopback: foreign, baseURL: baseURL, vaultURL: vaultURL))
    }

    func testLoopbackMappingRejectsHttpsScheme() {
        let baseURL = URL(string: "http://127.0.0.1:50505/\(token)/")!
        let httpsURL = URL(string: "https://127.0.0.1:50505/\(token)/index.html")!
        XCTAssertNil(VaultHTTPServer.fileURL(forLoopback: httpsURL, baseURL: baseURL, vaultURL: vaultURL))
    }

    // MARK: - Integration over a real loopback socket

    func testServesOverLoopbackSocket() throws {
        let server = VaultHTTPServer()
        defer { server.stop() }

        let baseBox = Box<URL?>(nil)
        let ready = DispatchSemaphore(value: 0)
        server.start(vaultURL: vaultURL) { url in
            baseBox.value = url
            ready.signal()
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "server did not become ready")
        let baseURL = try XCTUnwrap(baseBox.value)

        let resourceURL = try XCTUnwrap(
            VaultHTTPServer.resourceURL(
                forFileAt: vaultURL.appendingPathComponent("index.html"),
                baseURL: baseURL,
                vaultURL: vaultURL
            )
        )

        let statusBox = Box<Int?>(nil)
        let bodyBox = Box<String?>(nil)
        let fetched = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: resourceURL) { data, response, _ in
            statusBox.value = (response as? HTTPURLResponse)?.statusCode
            bodyBox.value = data.flatMap { String(data: $0, encoding: .utf8) }
            fetched.signal()
        }.resume()
        XCTAssertEqual(fetched.wait(timeout: .now() + 5), .success, "request did not complete")

        XCTAssertEqual(statusBox.value, 200)
        XCTAssertEqual(bodyBox.value, "<h1>Hi</h1>")
    }
}
