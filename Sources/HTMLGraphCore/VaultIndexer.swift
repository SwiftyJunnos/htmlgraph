import CryptoKit
import Foundation

public struct VaultIndexer {
    private let extractor: HTMLMetadataExtractor
    private let normalizer: LinkNormalizer

    public init(
        extractor: HTMLMetadataExtractor = HTMLMetadataExtractor(),
        normalizer: LinkNormalizer = LinkNormalizer()
    ) {
        self.extractor = extractor
        self.normalizer = normalizer
    }

    public func indexVault(at vaultURL: URL) throws -> VaultIndex {
        let fileURLs = try htmlFiles(in: vaultURL)
        let knownIds = Set(fileURLs.map { relativePath(for: $0, in: vaultURL) })

        let documents = try fileURLs.map { fileURL in
            let html = try String(contentsOf: fileURL, encoding: .utf8)
            let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            let relative = relativePath(for: fileURL, in: vaultURL)
            return DocumentNode(
                id: relative,
                path: relative,
                absolutePath: fileURL.path,
                title: try extractor.title(from: html, fallbackFilename: fileURL.lastPathComponent),
                contentHash: sha256(html),
                lastModified: values.contentModificationDate ?? .distantPast
            )
        }.sorted { $0.path < $1.path }

        var edges: [LinkEdge] = []
        for fileURL in fileURLs {
            let sourceId = relativePath(for: fileURL, in: vaultURL)
            let html = try String(contentsOf: fileURL, encoding: .utf8)
            for rawLink in try extractor.links(from: html) {
                let normalized = normalizer.normalize(
                    href: rawLink.href,
                    sourcePath: sourceId,
                    knownDocumentIds: knownIds
                )
                edges.append(LinkEdge(
                    sourceId: sourceId,
                    targetId: normalized.status == .resolved || normalized.status == .sameDocument ? normalized.targetPath : nil,
                    href: rawLink.href,
                    normalizedTargetPath: normalized.targetPath,
                    fragment: normalized.fragment,
                    linkText: rawLink.text,
                    status: normalized.status
                ))
            }
        }

        let backlinks = Dictionary(grouping: edges.filter { $0.status == .resolved }) { edge in
            edge.targetId ?? ""
        }
        let unresolved = Dictionary(grouping: edges.filter { $0.status == .unresolved }) { edge in
            edge.sourceId
        }

        return VaultIndex(
            vaultId: vaultURL.standardizedFileURL.path,
            documents: documents,
            edges: edges,
            backlinks: backlinks,
            unresolvedLinks: unresolved,
            lastIndexedAt: Date()
        )
    }

    private func htmlFiles(in vaultURL: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: vaultURL,
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
