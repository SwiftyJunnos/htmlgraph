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

    /// Indexes a vault over `fileSystem`. Backend-agnostic: the same logic runs against the
    /// local filesystem (`LocalFileSystem`) today and a remote (SFTP) backend later.
    public func indexVault(fileSystem: VaultFileSystem) async throws -> VaultIndex {
        let entries = try await fileSystem.enumerateFiles(under: "")
            .filter { isHTML($0.relativePath) && !isInboxPath($0.relativePath) }
            .sorted { $0.relativePath < $1.relativePath }
        let knownIds = Set(entries.map(\.relativePath))

        // Read each file exactly ONCE — the node (title/hash) and its outgoing edges are both
        // derived from the same buffer (previously each file was read twice). mtime comes from
        // the enumeration so there's no extra per-file stat either.
        var documents: [DocumentNode] = []
        documents.reserveCapacity(entries.count)
        var edges: [LinkEdge] = []
        for entry in entries {
            let html = try await fileSystem.readText(at: entry.relativePath)
            documents.append(try documentNode(
                relative: entry.relativePath,
                html: html,
                absolutePath: fileSystem.absolutePath(for: entry.relativePath) ?? "",
                lastModified: entry.modificationDate
            ))
            edges.append(contentsOf: try linkEdges(forSource: entry.relativePath, html: html, knownDocumentIds: knownIds))
        }

        return VaultIndex(
            vaultId: fileSystem.vaultIdentity,
            documents: documents,
            edges: edges,
            backlinks: backlinks(from: edges),
            unresolvedLinks: unresolvedLinks(from: edges),
            lastIndexedAt: Date()
        )
    }

    /// Convenience: index a local vault directory. Wraps `indexVault(fileSystem:)` with a
    /// `LocalFileSystem` rooted at `vaultURL`.
    public func indexVault(at vaultURL: URL) async throws -> VaultIndex {
        try await indexVault(fileSystem: LocalFileSystem(root: vaultURL))
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
        fileSystem: VaultFileSystem
    ) async throws -> VaultIndex {
        // The file set is constant for an in-place edit, so the known-id set — which
        // drives link resolution — is exactly the existing documents' ids.
        let knownIds = Set(existing.documents.map(\.id))
        guard let existingNode = existing.documents.first(where: { $0.id == changedRelativePath }) else {
            throw IncrementalReindexError.unknownDocument(changedRelativePath)
        }

        let html = try await fileSystem.readText(at: changedRelativePath)
        let lastModified = (try? await fileSystem.metadata(at: changedRelativePath).modificationDate) ?? .distantPast
        // An in-place edit doesn't move the file, so `absolutePath` is invariant — preserve
        // the existing node's value (it's discarded into `newNode` below anyway).
        let recomputed = try documentNode(
            relative: changedRelativePath,
            html: html,
            absolutePath: existingNode.absolutePath,
            lastModified: lastModified
        )
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

    /// Convenience: incremental reindex against a local vault directory.
    public func reindexDocument(_ existing: VaultIndex, changedRelativePath: String, vaultURL: URL) async throws -> VaultIndex {
        try await reindexDocument(existing, changedRelativePath: changedRelativePath, fileSystem: LocalFileSystem(root: vaultURL))
    }

    // MARK: - Shared building blocks (used by both full and incremental indexing)

    /// Builds the `DocumentNode` for one file. `relative` is the vault-relative path
    /// (the document id); `html` is the file's decoded UTF-8 contents.
    private func documentNode(relative: String, html: String, absolutePath: String, lastModified: Date) throws -> DocumentNode {
        DocumentNode(
            id: relative,
            path: relative,
            absolutePath: absolutePath,
            title: try extractor.title(from: html, fallbackFilename: (relative as NSString).lastPathComponent),
            contentHash: sha256(html),
            lastModified: lastModified
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

    private func isHTML(_ relativePath: String) -> Bool {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    private func isInboxPath(_ relativePath: String) -> Bool {
        InboxScanner.isInboxPath(relativePath)
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
