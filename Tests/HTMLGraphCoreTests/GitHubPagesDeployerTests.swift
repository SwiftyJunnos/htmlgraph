import XCTest
@testable import HTMLGraphCore

final class GitHubPagesDeployerTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testDeployableFilesIncludeNoJekyllAndSkipInternalFiles() throws {
        let siteURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: siteURL) }

        try write("home", to: siteURL.appendingPathComponent("index.html"))
        try write("", to: siteURL.appendingPathComponent(".nojekyll"))
        try write("marker", to: siteURL.appendingPathComponent(".htmlgraph-static-site"))
        try write("asset", to: siteURL.appendingPathComponent("vault/assets/app.css"))
        try write("secret", to: siteURL.appendingPathComponent(".hidden/secret.txt"))

        let files = try GitHubPagesDeployer.deployableFiles(in: siteURL).map(\.relativePath)

        XCTAssertEqual(files, [".nojekyll", "index.html", "vault/assets/app.css"])
    }

    func testRepositoriesReturnsWritableRepos() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/user/repos")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
            return try jsonResponse(for: request, body: [
                [
                    "name": "site",
                    "full_name": "octocat/site",
                    "owner": ["login": "octocat"],
                    "permissions": ["push": true, "admin": false]
                ],
                [
                    "name": "read-only",
                    "full_name": "octocat/read-only",
                    "owner": ["login": "octocat"],
                    "permissions": ["push": false, "admin": false]
                ]
            ])
        }

        let repositories = try await makeDeployer().repositories(token: "token-123")

        XCTAssertEqual(repositories, [
            GitHubRepository(owner: "octocat", name: "site", fullName: "octocat/site")
        ])
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLGraphGitHubPages-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDeployer() -> GitHubPagesDeployer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return GitHubPagesDeployer(session: URLSession(configuration: configuration))
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw GitHubPagesDeploymentError.invalidResponse }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func jsonResponse(for request: URLRequest, body: Any) throws -> (HTTPURLResponse, Data) {
    let data = try JSONSerialization.data(withJSONObject: body)
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, data)
}
