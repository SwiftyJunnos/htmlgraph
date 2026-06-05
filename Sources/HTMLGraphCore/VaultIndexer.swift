import CryptoKit
import Foundation

public enum IncrementalReindexError: Error, Equatable {
    /// `reindexDocument` was asked to patch a path that isn't an existing indexed
    /// document. In-place content edits keep the file set constant; creating or
    /// deleting a file must go through a full `indexVault` instead.
    case unknownDocument(String)
}

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
            .sorted { relativePath(for: $0, in: vaultURL) < relativePath(for: $1, in: vaultURL) }
        let knownIds = Set(fileURLs.map { relativePath(for: $0, in: vaultURL) })

        let documents = try fileURLs.map { fileURL -> DocumentNode in
            let relative = relativePath(for: fileURL, in: vaultURL)
            let html = try String(contentsOf: fileURL, encoding: .utf8)
            return try documentNode(at: fileURL, relative: relative, html: html)
        }

        var edges: [LinkEdge] = []
        for fileURL in fileURLs {
            let sourceId = relativePath(for: fileURL, in: vaultURL)
            let html = try String(contentsOf: fileURL, encoding: .utf8)
            edges.append(contentsOf: try linkEdges(forSource: sourceId, html: html, knownDocumentIds: knownIds))
        }

        return VaultIndex(
            vaultId: vaultURL.standardizedFileURL.path,
            documents: documents,
            edges: edges,
            backlinks: backlinks(from: edges),
            unresolvedLinks: unresolvedLinks(from: edges),
            lastIndexedAt: Date()
        )
    }

    /// Re-parses a single changed file against an existing index and returns a patched
    /// `VaultIndex`, avoiding a full vault rescan. Intended for IN-PLACE content edits:
    /// the file set is assumed unchanged, so every other document's links keep the same
    /// resolution status. File creation/deletion (which changes `knownDocumentIds` and
    /// can flip other files' links between resolved/unresolved) must use `indexVault`.
    ///
    /// Builds on the exact same node/edge/grouping helpers as `indexVault`, so for the
    /// same on-disk state the result is field-for-field equal to a full reindex (except
    /// `lastIndexedAt`). `IncrementalReindexTests` guards that equivalence.
    public func reindexDocument(
        _ existing: VaultIndex,
        changedRelativePath: String,
        vaultURL: URL
    ) throws -> VaultIndex {
        // The file set is constant for an in-place edit, so the known-id set — which
        // drives link resolution — is exactly the existing documents' ids.
        let knownIds = Set(existing.documents.map(\.id))
        guard let existingNode = existing.documents.first(where: { $0.id == changedRelativePath }) else {
            throw IncrementalReindexError.unknownDocument(changedRelativePath)
        }

        let fileURL = vaultURL.appendingPathComponent(changedRelativePath)
        let html = try String(contentsOf: fileURL, encoding: .utf8)
        let recomputed = try documentNode(at: fileURL, relative: changedRelativePath, html: html)
        // An in-place edit doesn't move the file, so `absolutePath` is invariant. Preserve
        // the existing node's value rather than the one derived from the freshly built
        // `fileURL` — `indexVault`'s enumerator yields symlink-resolved paths
        // (/private/var/…) that a re-derived URL (/var/…) wouldn't match, which would
        // otherwise diverge from a full reindex.
        let newNode = DocumentNode(
            id: recomputed.id,
            path: recomputed.path,
            absolutePath: existingNode.absolutePath,
            title: recomputed.title,
            contentHash: recomputed.contentHash,
            lastModified: recomputed.lastModified
        )
        let newEdges = try linkEdges(forSource: changedRelativePath, html: html, knownDocumentIds: knownIds)

        // Replace the changed document in place; its id/path is unchanged, so the
        // existing (path-sorted) order is preserved.
        let documents = existing.documents.map { $0.id == changedRelativePath ? newNode : $0 }

        // Rebuild the global edge list in document order, substituting just this file's
        // edges. `indexVault` appends edges per file in path-sorted order, and documents
        // are in that same order — so iterating documents and concatenating each one's
        // edges reproduces the full-reindex ordering exactly.
        var edgesBySource: [String: [LinkEdge]] = [:]
        for edge in existing.edges {
            edgesBySource[edge.sourceId, default: []].append(edge)
        }
        edgesBySource[changedRelativePath] = newEdges
        let edges = documents.flatMap { edgesBySource[$0.id] ?? [] }

        return VaultIndex(
            vaultId: existing.vaultId,
            documents: documents,
            edges: edges,
            backlinks: backlinks(from: edges),
            unresolvedLinks: unresolvedLinks(from: edges),
            lastIndexedAt: Date()
        )
    }

    // MARK: - Shared building blocks (used by both full and incremental indexing)

    /// Builds the `DocumentNode` for one file. `relative` is the vault-relative path
    /// (the document id); `html` is the file's decoded UTF-8 contents.
    private func documentNode(at fileURL: URL, relative: String, html: String) throws -> DocumentNode {
        let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        return DocumentNode(
            id: relative,
            path: relative,
            absolutePath: fileURL.path,
            title: try extractor.title(from: html, fallbackFilename: fileURL.lastPathComponent),
            contentHash: sha256(html),
            lastModified: values.contentModificationDate ?? .distantPast
        )
    }

    /// Extracts and normalizes one file's outgoing links into `LinkEdge`s, in document
    /// order, with stable `sourceId#link-<ordinal>` ids.
    private func linkEdges(forSource sourceId: String, html: String, knownDocumentIds: Set<String>) throws -> [LinkEdge] {
        try extractor.links(from: html).enumerated().map { ordinal, rawLink in
            let normalized = normalizer.normalize(
                href: rawLink.href,
                sourcePath: sourceId,
                knownDocumentIds: knownDocumentIds
            )
            return LinkEdge(
                id: "\(sourceId)#link-\(ordinal)",
                sourceId: sourceId,
                targetId: normalized.status == .resolved || normalized.status == .sameDocument ? normalized.targetPath : nil,
                href: rawLink.href,
                normalizedTargetPath: normalized.targetPath,
                fragment: normalized.fragment,
                linkText: rawLink.text,
                status: normalized.status
            )
        }
    }

    /// Backlinks: resolved edges grouped by their target document.
    private func backlinks(from edges: [LinkEdge]) -> [String: [LinkEdge]] {
        sortedGroups(Dictionary(grouping: edges.filter { $0.status == .resolved }) { edge in
            edge.targetId ?? ""
        })
    }

    /// Unresolved links: unresolved edges grouped by their source document.
    private func unresolvedLinks(from edges: [LinkEdge]) -> [String: [LinkEdge]] {
        sortedGroups(Dictionary(grouping: edges.filter { $0.status == .unresolved }) { edge in
            edge.sourceId
        })
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
            guard ext == "html" || ext == "htm" else { return nil }
            let relative = relativePath(for: url, in: vaultURL)
            return isInboxPath(relative) ? nil : url
        }
    }

    private func isInboxPath(_ relativePath: String) -> Bool {
        relativePath == InboxScanner.inboxDirectoryName ||
            relativePath.hasPrefix("\(InboxScanner.inboxDirectoryName)/")
    }

    private func relativePath(for fileURL: URL, in vaultURL: URL) -> String {
        let base = vaultURL.standardizedFileURL.path
        let full = fileURL.standardizedFileURL.path
        return String(full.dropFirst(base.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func sha256(_ string: String) -> String {
        Self.contentHash(forHTML: string)
    }

    /// The canonical content hash for a document's decoded text — `SHA256` over its
    /// UTF-8 bytes — matching `DocumentNode.contentHash`. Exposed so the editor's save
    /// path computes conflict-detection hashes identically to the indexer; hashing raw
    /// file bytes (BOM/CRLF) or a stale node's hash would produce phantom conflicts.
    public static func contentHash(forHTML html: String) -> String {
        let digest = SHA256.hash(data: Data(html.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func sortedGroups(_ groups: [String: [LinkEdge]]) -> [String: [LinkEdge]] {
        groups.mapValues { edges in
            edges.sorted { lhs, rhs in
                if lhs.sourceId != rhs.sourceId { return lhs.sourceId < rhs.sourceId }
                if lhs.href != rhs.href { return lhs.href < rhs.href }
                return lhs.id < rhs.id
            }
        }
    }
}
