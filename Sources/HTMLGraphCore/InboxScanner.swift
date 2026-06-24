import CryptoKit
import Foundation

public struct InboxScanner {
    public static let inboxDirectoryName = "Inbox"

    private let extractor: HTMLMetadataExtractor

    public init(extractor: HTMLMetadataExtractor = HTMLMetadataExtractor()) {
        self.extractor = extractor
    }

    /// Scans the vault's `Inbox/` for unfiled HTML notes over `fileSystem`. Backend-agnostic:
    /// the same logic runs against the local filesystem today and a remote backend later.
    /// Returns items whose `id`/`path` are vault-relative (e.g. `Inbox/draft.html`).
    public func scanInbox(fileSystem: VaultFileSystem) async throws -> [InboxItem] {
        let entries = try await fileSystem.enumerateFiles(under: Self.inboxDirectoryName)
            .filter { isHTML($0.relativePath) }
            .sorted { $0.relativePath < $1.relativePath }

        var items: [InboxItem] = []
        items.reserveCapacity(entries.count)
        for entry in entries {
            let html = try await fileSystem.readText(at: entry.relativePath)
            items.append(InboxItem(
                id: entry.relativePath,
                path: entry.relativePath,
                absolutePath: fileSystem.absolutePath(for: entry.relativePath) ?? "",
                title: try extractor.title(from: html, fallbackFilename: (entry.relativePath as NSString).lastPathComponent),
                contentHash: sha256(html),
                lastModified: entry.modificationDate
            ))
        }
        return items
    }

    /// Convenience: scan a local vault directory.
    public func scanInbox(at vaultURL: URL) async throws -> [InboxItem] {
        try await scanInbox(fileSystem: LocalFileSystem(root: vaultURL))
    }

    private func isHTML(_ relativePath: String) -> Bool {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    private func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
