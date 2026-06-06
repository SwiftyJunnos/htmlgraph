import Foundation

/// The in-memory semantic index: one vector per document, plus the identity of the
/// provider that produced them (so callers can detect a stale provider).
public struct EmbeddingIndex: Equatable, Sendable {
    public let providerId: String
    public let dimension: Int
    public var entries: [String: EmbeddingRecord] // docId -> record

    public init(providerId: String, dimension: Int, entries: [String: EmbeddingRecord]) {
        self.providerId = providerId
        self.dimension = dimension
        self.entries = entries
    }
}

/// One ranked search result. `cosine` is the raw semantic similarity; `score` is
/// after the centrality re-rank. Both are exposed for debugging/tuning.
public struct ScoredHit: Equatable, Sendable {
    public let documentId: String
    public let cosine: Float
    public let centrality: Float
    public let score: Float

    public init(documentId: String, cosine: Float, centrality: Float, score: Float) {
        self.documentId = documentId
        self.cosine = cosine
        self.centrality = centrality
        self.score = score
    }
}

/// Orchestrates building/refreshing the embedding index and ranking queries.
///
/// `refresh` re-embeds only documents whose `(id, contentHash)` changed and prunes
/// entries for documents no longer in the index (ghost-node defense), then persists
/// via `VaultEmbeddingStore`. `search` embeds the query, cosine-ranks, and applies a
/// small link-graph-centrality re-rank so that near-ties favor well-connected notes.
public struct SemanticIndexer: Sendable {
    /// Weight of the centrality term in the final score. Semantics dominate; this
    /// only breaks near-ties. Tunable.
    public static let defaultCentralityWeight: Float = 0.08

    private let provider: EmbeddingProvider
    private let store: VaultEmbeddingStore
    private let maxCharsPerChunk: Int
    private let bodyTextLoader: @Sendable (DocumentNode) throws -> String

    public init(
        provider: EmbeddingProvider,
        store: VaultEmbeddingStore = VaultEmbeddingStore(),
        maxCharsPerChunk: Int = EmbeddingInput.defaultMaxCharsPerChunk,
        bodyTextLoader: @escaping @Sendable (DocumentNode) throws -> String = SemanticIndexer.diskBodyTextLoader
    ) {
        self.provider = provider
        self.store = store
        self.maxCharsPerChunk = maxCharsPerChunk
        self.bodyTextLoader = bodyTextLoader
    }

    /// Default loader: read the document's HTML from disk and extract its body text.
    public static let diskBodyTextLoader: @Sendable (DocumentNode) throws -> String = { node in
        let html = try String(contentsOf: URL(fileURLWithPath: node.absolutePath), encoding: .utf8)
        return try HTMLMetadataExtractor().bodyText(from: html)
    }

    // MARK: - Refresh

    /// Re-embeds changed documents, reuses cached vectors for unchanged ones, prunes
    /// ghosts, persists, and returns the updated in-memory index.
    @discardableResult
    public func refresh(index: VaultIndex, vaultURL: URL) async throws -> EmbeddingIndex {
        let cached = store.load(
            providerId: provider.identifier,
            dimension: provider.dimension,
            vaultURL: vaultURL
        ) ?? [:]

        var records: [String: EmbeddingRecord] = [:]
        records.reserveCapacity(index.documents.count)

        for document in index.documents {
            if let prior = cached[document.id], prior.contentHash == document.contentHash {
                records[document.id] = prior // unchanged ⇒ skip the model
                continue
            }
            let vector = try await embed(document: document)
            records[document.id] = EmbeddingRecord(contentHash: document.contentHash, vector: vector)
        }
        // Ghost prune is implicit: `records` only contains current document ids.

        try store.save(
            records,
            providerId: provider.identifier,
            dimension: provider.dimension,
            vaultURL: vaultURL
        )

        return EmbeddingIndex(
            providerId: provider.identifier,
            dimension: provider.dimension,
            entries: records
        )
    }

    /// Re-embeds exactly one document and returns its record (for the incremental
    /// editor-save hook). Does not touch the store; the caller patches the in-memory
    /// index and persists.
    public func embedRecord(for document: DocumentNode) async throws -> EmbeddingRecord {
        let vector = try await embed(document: document)
        return EmbeddingRecord(contentHash: document.contentHash, vector: vector)
    }

    private func embed(document: DocumentNode) async throws -> [Float] {
        let body = try bodyTextLoader(document)
        var chunks = EmbeddingInput.chunks(
            title: document.title,
            bodyText: body,
            maxCharsPerChunk: maxCharsPerChunk
        )
        if chunks.isEmpty {
            chunks = [EmbeddingInput.combinedText(title: document.title, bodyText: body)]
        }
        var chunkVectors: [[Float]] = []
        chunkVectors.reserveCapacity(chunks.count)
        for chunk in chunks {
            chunkVectors.append(try await provider.embed(chunk))
        }
        return EmbeddingMath.l2Normalized(EmbeddingMath.meanPooled(chunkVectors))
    }

    // MARK: - Search

    /// Embeds `query`, cosine-ranks every document in `index`, applies the centrality
    /// re-rank from `graph`, and returns the top `topK` hits (descending score,
    /// documentId as a stable tiebreak).
    public func search(
        query: String,
        in index: EmbeddingIndex,
        graph: VaultIndex,
        topK: Int,
        centralityWeight: Float = SemanticIndexer.defaultCentralityWeight
    ) async throws -> [ScoredHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, topK > 0, !index.entries.isEmpty else { return [] }

        let queryVector = EmbeddingMath.l2Normalized(try await provider.embed(trimmed))
        let degree = Self.degrees(in: graph)
        let maxDegree = degree.values.max() ?? 0

        var hits: [ScoredHit] = []
        hits.reserveCapacity(index.entries.count)
        for (documentId, record) in index.entries {
            let cosine = EmbeddingMath.cosineSimilarity(queryVector, record.vector)
            let centrality = Self.centralityScore(degree: degree[documentId] ?? 0, maxDegree: maxDegree)
            let score = cosine + centralityWeight * centrality
            hits.append(ScoredHit(documentId: documentId, cosine: cosine, centrality: centrality, score: score))
        }

        hits.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.documentId < rhs.documentId
        }
        return Array(hits.prefix(topK))
    }

    // MARK: - Centrality

    /// Degree of each document from **resolved** edges only (out-degree at the source,
    /// in-degree at the target). Unresolved/external/same-document links don't count.
    static func degrees(in graph: VaultIndex) -> [String: Int] {
        var degree: [String: Int] = [:]
        for edge in graph.edges where edge.status == .resolved {
            degree[edge.sourceId, default: 0] += 1
            if let target = edge.targetId {
                degree[target, default: 0] += 1
            }
        }
        return degree
    }

    /// `log(1 + degree) / log(1 + maxDegree)` in `[0, 1]`; `0` when the graph has no
    /// resolved edges.
    static func centralityScore(degree: Int, maxDegree: Int) -> Float {
        guard maxDegree > 0 else { return 0 }
        return Float(log(1.0 + Double(degree)) / log(1.0 + Double(maxDegree)))
    }
}
