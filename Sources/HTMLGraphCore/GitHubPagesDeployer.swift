import Foundation

public struct GitHubPagesDeploymentConfig: Equatable, Sendable {
    public let owner: String
    public let repo: String
    public let branch: String
    public let token: String

    public init(owner: String, repo: String, branch: String = "gh-pages", token: String) {
        self.owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        self.repo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        self.branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct GitHubPagesDeploymentResult: Equatable, Sendable {
    public let commitSHA: String
    public let pageURL: URL

    public init(commitSHA: String, pageURL: URL) {
        self.commitSHA = commitSHA
        self.pageURL = pageURL
    }
}

public enum GitHubPagesDeploymentError: LocalizedError, Equatable {
    case missingField(String)
    case invalidField(String)
    case noFiles
    case fileTooLarge(String)
    case invalidResponse
    case api(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingField(let name):
            return "GitHub \(name) is required."
        case .invalidField(let name):
            return "GitHub \(name) is invalid."
        case .noFiles:
            return "There is nothing to deploy."
        case .fileTooLarge(let path):
            return "“\(path)” is too large for GitHub's blob API."
        case .invalidResponse:
            return "GitHub returned an unexpected response."
        case .api(let status, let message):
            return "GitHub API error \(status): \(message)"
        }
    }
}

struct GitHubDeployableFile: Equatable {
    let relativePath: String
    let url: URL
}

public struct GitHubPagesDeployer {
    private let session: URLSession
    private static let apiVersion = "2022-11-28"
    private static let maxBlobSize = 100 * 1024 * 1024

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func deploy(siteDirectory: URL, config: GitHubPagesDeploymentConfig) async throws -> GitHubPagesDeploymentResult {
        try validate(config)
        let files = try Self.deployableFiles(in: siteDirectory)
        guard !files.isEmpty else { throw GitHubPagesDeploymentError.noFiles }

        let parentSHA = try await existingRefSHA(config: config)
        var entries: [CreateTreeRequest.Entry] = []
        entries.reserveCapacity(files.count)

        // ponytail: blob-per-file is simple and exact; switch to chunked/parallel uploads if vaults get huge.
        for file in files {
            let data = try Data(contentsOf: file.url)
            guard data.count <= Self.maxBlobSize else {
                throw GitHubPagesDeploymentError.fileTooLarge(file.relativePath)
            }
            let blob: SHAResponse = try await decoded(
                "POST",
                "/repos/\(config.owner)/\(config.repo)/git/blobs",
                token: config.token,
                body: BlobRequest(content: data.base64EncodedString(), encoding: "base64"),
                allowed: [201]
            )
            entries.append(.init(path: file.relativePath, mode: "100644", type: "blob", sha: blob.sha))
        }

        let tree: SHAResponse = try await decoded(
            "POST",
            "/repos/\(config.owner)/\(config.repo)/git/trees",
            token: config.token,
            body: CreateTreeRequest(tree: entries),
            allowed: [201]
        )
        let commit: SHAResponse = try await decoded(
            "POST",
            "/repos/\(config.owner)/\(config.repo)/git/commits",
            token: config.token,
            body: CreateCommitRequest(
                message: "Deploy HTMLGraph vault",
                tree: tree.sha,
                parents: parentSHA.map { [$0] } ?? []
            ),
            allowed: [201]
        )

        if parentSHA == nil {
            let _: RefResponse = try await decoded(
                "POST",
                "/repos/\(config.owner)/\(config.repo)/git/refs",
                token: config.token,
                body: CreateRefRequest(ref: "refs/heads/\(config.branch)", sha: commit.sha),
                allowed: [201]
            )
        } else {
            let _: RefResponse = try await decoded(
                "PATCH",
                "/repos/\(config.owner)/\(config.repo)/git/refs/heads/\(config.branch)",
                token: config.token,
                body: UpdateRefRequest(sha: commit.sha, force: true),
                allowed: [200]
            )
        }

        let pageURL = try await configurePages(config: config)
        return GitHubPagesDeploymentResult(commitSHA: commit.sha, pageURL: pageURL)
    }

    static func deployableFiles(in siteDirectory: URL) throws -> [GitHubDeployableFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isHiddenKey]
        let enumerator = FileManager.default.enumerator(
            at: siteDirectory,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        guard let enumerator else { return [] }

        var files: [GitHubDeployableFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let relative = relativePath(for: url, in: siteDirectory)
            guard relative != ".htmlgraph-static-site", relative != ".DS_Store" else { continue }
            guard relative == ".nojekyll" || !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            guard values.isHidden != true || relative == ".nojekyll" else { continue }
            files.append(GitHubDeployableFile(relativePath: relative, url: url))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func validate(_ config: GitHubPagesDeploymentConfig) throws {
        for (name, value) in [("owner", config.owner), ("repository", config.repo), ("branch", config.branch), ("token", config.token)] {
            guard !value.isEmpty else { throw GitHubPagesDeploymentError.missingField(name) }
        }
        guard !config.owner.contains("/") else { throw GitHubPagesDeploymentError.invalidField("owner") }
        guard !config.repo.contains("/") else { throw GitHubPagesDeploymentError.invalidField("repository") }
        guard !config.branch.hasPrefix("refs/") else { throw GitHubPagesDeploymentError.invalidField("branch") }
    }

    private func existingRefSHA(config: GitHubPagesDeploymentConfig) async throws -> String? {
        do {
            let ref: RefResponse = try await decoded(
                "GET",
                "/repos/\(config.owner)/\(config.repo)/git/ref/heads/\(config.branch)",
                token: config.token,
                allowed: [200]
            )
            return ref.object.sha
        } catch GitHubPagesDeploymentError.api(404, _) {
            return nil
        }
    }

    private func configurePages(config: GitHubPagesDeploymentConfig) async throws -> URL {
        let request = PagesSourceRequest(buildType: "legacy", source: .init(branch: config.branch, path: "/"))

        do {
            let _: PagesResponse = try await decoded(
                "GET",
                "/repos/\(config.owner)/\(config.repo)/pages",
                token: config.token,
                allowed: [200]
            )
            try await send(
                "PUT",
                "/repos/\(config.owner)/\(config.repo)/pages",
                token: config.token,
                body: request,
                allowed: [204]
            )
        } catch GitHubPagesDeploymentError.api(404, _) {
            let _: PagesResponse = try await decoded(
                "POST",
                "/repos/\(config.owner)/\(config.repo)/pages",
                token: config.token,
                body: request,
                allowed: [201]
            )
        }

        let pages: PagesResponse = try await decoded(
            "GET",
            "/repos/\(config.owner)/\(config.repo)/pages",
            token: config.token,
            allowed: [200]
        )
        guard let htmlURL = pages.htmlURL, let url = URL(string: htmlURL) else {
            throw GitHubPagesDeploymentError.invalidResponse
        }
        return url
    }

    private func decoded<Response: Decodable, Body: Encodable>(
        _ method: String,
        _ path: String,
        token: String,
        body: Body,
        allowed: Set<Int>
    ) async throws -> Response {
        try await decode(
            Response.self,
            from: send(method, path, token: token, bodyData: JSONEncoder().encode(body), allowed: allowed)
        )
    }

    private func decoded<Response: Decodable>(
        _ method: String,
        _ path: String,
        token: String,
        allowed: Set<Int>
    ) async throws -> Response {
        try await decode(Response.self, from: send(method, path, token: token, bodyData: nil, allowed: allowed))
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GitHubPagesDeploymentError.invalidResponse
        }
    }

    private func send<Body: Encodable>(
        _ method: String,
        _ path: String,
        token: String,
        body: Body,
        allowed: Set<Int>
    ) async throws {
        _ = try await send(method, path, token: token, bodyData: JSONEncoder().encode(body), allowed: allowed)
    }

    private func send(
        _ method: String,
        _ path: String,
        token: String,
        bodyData: Data?,
        allowed: Set<Int>
    ) async throws -> Data {
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw GitHubPagesDeploymentError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubPagesDeploymentError.invalidResponse
        }
        guard allowed.contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data).message)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GitHubPagesDeploymentError.api(status: http.statusCode, message: message)
        }
        return data
    }

    private static func relativePath(for fileURL: URL, in rootURL: URL) -> String {
        let base = rootURL.standardizedFileURL.path
        let full = fileURL.standardizedFileURL.path
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private struct BlobRequest: Encodable {
    let content: String
    let encoding: String
}

private struct SHAResponse: Decodable {
    let sha: String
}

private struct CreateTreeRequest: Encodable {
    struct Entry: Encodable {
        let path: String
        let mode: String
        let type: String
        let sha: String
    }

    let tree: [Entry]
}

private struct CreateCommitRequest: Encodable {
    let message: String
    let tree: String
    let parents: [String]
}

private struct CreateRefRequest: Encodable {
    let ref: String
    let sha: String
}

private struct UpdateRefRequest: Encodable {
    let sha: String
    let force: Bool
}

private struct RefResponse: Decodable {
    struct Object: Decodable {
        let sha: String
    }

    let object: Object
}

private struct PagesSourceRequest: Encodable {
    struct Source: Encodable {
        let branch: String
        let path: String
    }

    enum CodingKeys: String, CodingKey {
        case buildType = "build_type"
        case source
    }

    let buildType: String
    let source: Source
}

private struct PagesResponse: Decodable {
    enum CodingKeys: String, CodingKey {
        case htmlURL = "html_url"
    }

    let htmlURL: String?
}

private struct APIErrorResponse: Decodable {
    let message: String
}
