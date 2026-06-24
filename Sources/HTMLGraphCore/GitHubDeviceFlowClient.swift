import Foundation

public struct GitHubOAuthDeviceCode: Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let expiresAt: Date
    public let interval: Int

    public init(deviceCode: String, userCode: String, verificationURI: URL, expiresAt: Date, interval: Int) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresAt = expiresAt
        self.interval = interval
    }
}

public struct GitHubOAuthToken: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let refreshTokenExpiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, refreshTokenExpiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }
}

public enum GitHubDeviceFlowError: LocalizedError, Equatable {
    case missingClientID
    case authorizationPending
    case slowDown(interval: Int)
    case expiredToken
    case accessDenied
    case deviceFlowDisabled
    case invalidResponse
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "GitHub sign-in is not available in this build. Use a personal access token instead."
        case .authorizationPending:
            return "Waiting for GitHub authorization."
        case .slowDown:
            return "GitHub asked HTMLGraph to slow down authorization polling."
        case .expiredToken:
            return "GitHub authorization code expired. Try connecting again."
        case .accessDenied:
            return "GitHub authorization was cancelled."
        case .deviceFlowDisabled:
            return "Device Flow is disabled for this GitHub App."
        case .invalidResponse:
            return "GitHub returned an unexpected authorization response."
        case .api(let message):
            return message
        }
    }
}

public struct GitHubDeviceFlowClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func requestDeviceCode(clientID: String, scope: String = "") async throws -> GitHubOAuthDeviceCode {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw GitHubDeviceFlowError.missingClientID }

        var form = ["client_id": clientID]
        let scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scope.isEmpty { form["scope"] = scope }

        let response: DeviceCodeResponse = try await send(
            "https://github.com/login/device/code",
            form: form
        )
        guard let verificationURI = URL(string: response.verificationURI) else {
            throw GitHubDeviceFlowError.invalidResponse
        }
        return GitHubOAuthDeviceCode(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURI: verificationURI,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            interval: max(response.interval, 1)
        )
    }

    public func requestAccessToken(clientID: String, deviceCode: String) async throws -> GitHubOAuthToken {
        try await requestToken(form: [
            "client_id": clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ])
    }

    public func waitForAccessToken(clientID: String, deviceCode: GitHubOAuthDeviceCode) async throws -> GitHubOAuthToken {
        var interval = deviceCode.interval

        while Date() < deviceCode.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            do {
                return try await requestAccessToken(clientID: clientID, deviceCode: deviceCode.deviceCode)
            } catch GitHubDeviceFlowError.authorizationPending {
                continue
            } catch GitHubDeviceFlowError.slowDown(let nextInterval) {
                interval = max(nextInterval, interval + 5)
            }
        }

        throw GitHubDeviceFlowError.expiredToken
    }

    public func refreshAccessToken(clientID: String, refreshToken: String) async throws -> GitHubOAuthToken {
        try await requestToken(form: [
            "client_id": clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
    }

    private func requestToken(form: [String: String]) async throws -> GitHubOAuthToken {
        guard !(form["client_id"] ?? "").isEmpty else { throw GitHubDeviceFlowError.missingClientID }

        let response: TokenResponse = try await send("https://github.com/login/oauth/access_token", form: form)
        if let error = response.error {
            throw Self.error(named: error, interval: response.interval)
        }
        guard let accessToken = response.accessToken else {
            throw GitHubDeviceFlowError.invalidResponse
        }
        return GitHubOAuthToken(
            accessToken: accessToken,
            refreshToken: response.refreshToken,
            expiresAt: response.expiresIn.map { Date().addingTimeInterval($0) },
            refreshTokenExpiresAt: response.refreshTokenExpiresIn.map { Date().addingTimeInterval($0) }
        )
    }

    private func send<Response: Decodable>(_ urlString: String, form: [String: String]) async throws -> Response {
        guard let url = URL(string: urlString) else { throw GitHubDeviceFlowError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Self.formData(form)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubDeviceFlowError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw GitHubDeviceFlowError.api(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubDeviceFlowError.invalidResponse
        }
    }

    private static func formData(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func error(named name: String, interval: Int?) -> GitHubDeviceFlowError {
        switch name {
        case "authorization_pending":
            return .authorizationPending
        case "slow_down":
            return .slowDown(interval: interval ?? 5)
        case "expired_token", "token_expired":
            return .expiredToken
        case "access_denied":
            return .accessDenied
        case "device_flow_disabled":
            return .deviceFlowDisabled
        default:
            return .api(name)
        }
    }
}

private struct DeviceCodeResponse: Decodable {
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }

    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let expiresIn: Int
    let interval: Int
}

private struct TokenResponse: Decodable {
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case error
        case interval
    }

    let accessToken: String?
    let refreshToken: String?
    let expiresIn: TimeInterval?
    let refreshTokenExpiresIn: TimeInterval?
    let error: String?
    let interval: Int?
}
