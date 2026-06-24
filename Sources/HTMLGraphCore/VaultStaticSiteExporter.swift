import Foundation

public enum VaultStaticSiteExportError: LocalizedError, Equatable {
    case destinationInsideVault
    case destinationNotDirectory
    case destinationNotEmpty

    public var errorDescription: String? {
        switch self {
        case .destinationInsideVault:
            return "Choose an export folder outside the vault."
        case .destinationNotDirectory:
            return "The export destination is not a folder."
        case .destinationNotEmpty:
            return "Choose an empty folder, or an existing HTMLGraph web export folder."
        }
    }
}

public struct VaultStaticSiteExporter {
    private static let markerFileName = ".htmlgraph-static-site"
    private static let vaultDirectoryName = "vault"

    public init() {}

    @discardableResult
    public func export(index: VaultIndex, vaultURL: URL, to destinationURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let destinationURL = destinationURL.standardizedFileURL
        let vaultURL = vaultURL.standardizedFileURL

        guard !Self.isInside(destinationURL, base: vaultURL) else {
            throw VaultStaticSiteExportError.destinationInsideVault
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw VaultStaticSiteExportError.destinationNotDirectory }
            try prepareExistingDestination(destinationURL)
        } else {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        }

        let publicVaultURL = destinationURL.appendingPathComponent(Self.vaultDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: publicVaultURL, withIntermediateDirectories: true)
        try copyPublicVaultFiles(from: vaultURL, to: publicVaultURL)
        try catalogHTML(for: index).write(
            to: destinationURL.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try "HTMLGraph static web export\n".write(
            to: destinationURL.appendingPathComponent(Self.markerFileName),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: destinationURL.appendingPathComponent(".nojekyll"), options: [.atomic])

        return destinationURL
    }

    private func prepareExistingDestination(_ destinationURL: URL) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(atPath: destinationURL.path)
            .filter { $0 != ".DS_Store" }
        let markerExists = contents.contains(Self.markerFileName)
        guard contents.isEmpty || markerExists else {
            throw VaultStaticSiteExportError.destinationNotEmpty
        }

        let indexURL = destinationURL.appendingPathComponent("index.html")
        let vaultURL = destinationURL.appendingPathComponent(Self.vaultDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: indexURL.path) {
            try fileManager.removeItem(at: indexURL)
        }
        if fileManager.fileExists(atPath: vaultURL.path) {
            try fileManager.removeItem(at: vaultURL)
        }
    }

    private func copyPublicVaultFiles(from vaultURL: URL, to publicVaultURL: URL) throws {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let enumerator = fileManager.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        guard let enumerator else { return }

        for case let sourceURL as URL in enumerator {
            let relative = Self.relativePath(for: sourceURL, in: vaultURL)
            let values = try sourceURL.resourceValues(forKeys: keys)

            if values.isSymbolicLink == true || Self.isExcluded(relativePath: relative) {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true else { continue }
            let targetURL = publicVaultURL.appendingPathComponent(relative, isDirectory: false)
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.copyItem(at: sourceURL, to: targetURL)
        }
    }

    private func catalogHTML(for index: VaultIndex) -> String {
        let rows = index.documents.map { document in
            let href = "vault/" + Self.encodedPath(document.path)
            return #"<li><a href="\#(href)">\#(Self.htmlEscaped(document.title))</a><span>\#(Self.htmlEscaped(document.path))</span></li>"#
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>HTMLGraph Vault</title>
          <style>
            :root { color-scheme: light dark; }
            body { margin: 0; font: 15px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: Canvas; color: CanvasText; }
            main { max-width: 880px; margin: 0 auto; padding: 32px 20px; }
            h1 { font-size: 24px; margin: 0 0 20px; }
            ul { list-style: none; margin: 0; padding: 0; border-top: 1px solid color-mix(in srgb, CanvasText 14%, transparent); }
            li { display: grid; grid-template-columns: minmax(0, 1fr) minmax(160px, 280px); gap: 16px; padding: 10px 0; border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent); }
            a { color: LinkText; text-decoration: none; overflow-wrap: anywhere; }
            a:hover { text-decoration: underline; }
            span { color: color-mix(in srgb, CanvasText 58%, transparent); font-size: 12px; overflow-wrap: anywhere; }
            @media (max-width: 640px) { li { grid-template-columns: 1fr; gap: 3px; } }
          </style>
        </head>
        <body>
          <main>
            <h1>HTMLGraph Vault</h1>
            <ul>
        \(rows)
            </ul>
          </main>
        </body>
        </html>
        """
    }

    private static func isExcluded(relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first else { return true }
        return first == InboxScanner.inboxDirectoryName ||
            parts.contains { $0.hasPrefix(".") } ||
            relativePath == VaultAgentGuideWriter.agentsFileName ||
            relativePath == VaultAgentGuideWriter.claudeFileName
    }

    private static func isInside(_ url: URL, base: URL) -> Bool {
        let path = url.standardizedFileURL.pathComponents
        let basePath = base.standardizedFileURL.pathComponents
        return path.count >= basePath.count && zip(basePath, path).allSatisfy { $0 == $1 }
    }

    private static func relativePath(for fileURL: URL, in vaultURL: URL) -> String {
        let base = vaultURL.standardizedFileURL.path
        let full = fileURL.standardizedFileURL.path
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func encodedPath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/#?%&<>\"'")
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static func htmlEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
