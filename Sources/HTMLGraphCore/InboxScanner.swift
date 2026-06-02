import CryptoKit
import Foundation

public struct InboxScanner {
    public static let inboxDirectoryName = "Inbox"

    private let extractor: HTMLMetadataExtractor
    private let fileManager: FileManager

    public init(
        extractor: HTMLMetadataExtractor = HTMLMetadataExtractor(),
        fileManager: FileManager = .default
    ) {
        self.extractor = extractor
        self.fileManager = fileManager
    }

    public func scanInbox(at vaultURL: URL) throws -> [InboxItem] {
        let inboxURL = vaultURL.appendingPathComponent(Self.inboxDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: inboxURL.path) else {
            return []
        }

        let fileURLs = try htmlFiles(in: inboxURL)
            .sorted { relativePath(for: $0, in: vaultURL) < relativePath(for: $1, in: vaultURL) }

        return try fileURLs.map { fileURL in
            let html = try String(contentsOf: fileURL, encoding: .utf8)
            let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            let relative = relativePath(for: fileURL, in: vaultURL)
            return InboxItem(
                id: relative,
                path: relative,
                absolutePath: fileURL.standardizedFileURL.path,
                title: try extractor.title(from: html, fallbackFilename: fileURL.lastPathComponent),
                contentHash: sha256(html),
                lastModified: values.contentModificationDate ?? .distantPast
            )
        }
    }

    private func htmlFiles(in inboxURL: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = fileManager.enumerator(
            at: inboxURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        guard let enumerator else { return [] }

        return try enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return nil }
            let ext = url.pathExtension.lowercased()
            return (ext == "html" || ext == "htm") ? url : nil
        }
    }

    private func relativePath(for fileURL: URL, in vaultURL: URL) -> String {
        let base = vaultURL.standardizedFileURL.path
        let full = fileURL.standardizedFileURL.path
        return String(full.dropFirst(base.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
