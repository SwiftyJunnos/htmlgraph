import XCTest
@testable import HTMLGraphCore

final class GitHubDeviceFlowClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testRequestDeviceCodeDecodesGitHubResponse() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/login/device/code")
            return try jsonResponse(for: request, body: [
                "device_code": "device-123",
                "user_code": "ABCD-EFGH",
                "verification_uri": "https://github.com/login/device",
                "expires_in": 900,
                "interval": 5
            ])
        }

        let code = try await makeClient().requestDeviceCode(clientID: "Iv1.client")

        XCTAssertEqual(code.deviceCode, "device-123")
        XCTAssertEqual(code.userCode, "ABCD-EFGH")
        XCTAssertEqual(code.verificationURI.absoluteString, "https://github.com/login/device")
        XCTAssertEqual(code.interval, 5)
        XCTAssertGreaterThan(code.expiresAt, Date())
    }

    func testSlowDownErrorKeepsGitHubInterval() async throws {
        URLProtocolStub.handler = { request in
            try jsonResponse(for: request, body: [
                "error": "slow_down",
                "interval": 10
            ])
        }

        do {
            _ = try await makeClient().requestAccessToken(clientID: "Iv1.client", deviceCode: "device-123")
            XCTFail("Expected slow_down")
        } catch GitHubDeviceFlowError.slowDown(let interval) {
            XCTAssertEqual(interval, 10)
        }
    }

    private func makeClient() -> GitHubDeviceFlowClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return GitHubDeviceFlowClient(session: URLSession(configuration: configuration))
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
            guard let handler = Self.handler else { throw GitHubDeviceFlowError.invalidResponse }
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

private func jsonResponse(for request: URLRequest, body: [String: Any]) throws -> (HTTPURLResponse, Data) {
    let data = try JSONSerialization.data(withJSONObject: body)
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, data)
}
