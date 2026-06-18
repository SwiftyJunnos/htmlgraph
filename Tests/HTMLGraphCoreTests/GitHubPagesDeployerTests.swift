import XCTest
@testable import HTMLGraphCore

final class GitHubPagesDeployerTests: XCTestCase {
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
}
