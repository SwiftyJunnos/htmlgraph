import Foundation
import HTMLGraphCore
import WebKit

final class VaultResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private let vaultURL: URL
    private let policy: VaultSecurityPolicy

    init(vaultURL: URL, policy: VaultSecurityPolicy) {
        self.vaultURL = vaultURL
        self.policy = policy
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = Self.fileURL(for: requestURL, vaultURL: vaultURL, policy: policy) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let response = URLResponse(
                url: requestURL,
                mimeType: Self.mimeType(for: fileURL),
                expectedContentLength: data.count,
                textEncodingName: Self.textEncodingName(for: fileURL)
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    nonisolated static func vaultURL(for fileURL: URL, vaultURL: URL) -> URL? {
        guard let relativePath = vaultRelativePath(for: fileURL, in: vaultURL) else { return nil }

        var components = URLComponents()
        components.scheme = "htmlgraph"
        components.host = "vault"
        components.percentEncodedPath = "/" + relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return components.url
    }

    nonisolated static func fileURL(for resourceURL: URL, vaultURL: URL, policy: VaultSecurityPolicy) -> URL? {
        guard resourceURL.scheme?.lowercased() == "htmlgraph",
              resourceURL.host?.lowercased() == "vault" else {
            return nil
        }

        guard let encodedPath = URLComponents(
            url: resourceURL,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath else {
            return nil
        }
        guard encodedPath.hasPrefix("/"), encodedPath.count > 1 else { return nil }

        let encodedRelativePath = String(encodedPath.dropFirst())
        guard let relativePath = encodedRelativePath.removingPercentEncoding,
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0") else {
            return nil
        }

        let candidateURL = vaultURL
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL

        guard policy.allows(candidateURL, vaultRoot: vaultURL) else { return nil }
        return candidateURL
    }

    nonisolated static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "html", "htm":
            return "text/html"
        case "css":
            return "text/css"
        case "js":
            return "text/javascript"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        default:
            return "application/octet-stream"
        }
    }

    private nonisolated static func textEncodingName(for fileURL: URL) -> String? {
        switch fileURL.pathExtension.lowercased() {
        case "html", "htm", "css", "js", "svg":
            return "utf-8"
        default:
            return nil
        }
    }

    private nonisolated static func vaultRelativePath(for fileURL: URL, in vaultURL: URL) -> String? {
        let fileComponents = fileURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let vaultComponents = vaultURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents

        guard fileComponents.count > vaultComponents.count else { return nil }
        guard zip(vaultComponents, fileComponents).allSatisfy({ $0 == $1 }) else { return nil }

        return fileComponents
            .dropFirst(vaultComponents.count)
            .joined(separator: "/")
    }
}
