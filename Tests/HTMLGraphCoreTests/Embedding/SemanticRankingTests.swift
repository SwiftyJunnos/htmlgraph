import XCTest
@testable import HTMLGraphCore

final class SemanticRankingTests: XCTestCase {
    // Query ~ [1,0,0]. A is the exact match (cosine 1.0); B is a near-match
    // (cosine ~0.99) but highly connected; C is unrelated (cosine 0).
    private let query = "q"
    private func provider() -> FixedEmbeddingProvider {
        FixedEmbeddingProvider(dimension: 3, vectors: [query: [1, 0, 0]])
    }
    private func embeddingIndex() -> EmbeddingIndex {
        EmbeddingIndex(providerId: "fixed.v1", dimension: 3, entries: [
            "A": EmbeddingRecord(contentHash: "a", vector: [1, 0, 0]),
            "B": EmbeddingRecord(contentHash: "b", vector: [0.99, 0.14, 0]),
            "C": EmbeddingRecord(contentHash: "c", vector: [0, 1, 0]),
        ])
    }
    // B has resolved in-degree 3; A and C have degree 0.
    private func graph() -> VaultIndex {
        VaultIndex(
            vaultId: "v",
            documents: [],
            edges: [
                EmbeddingTestFixtures.resolvedEdge(from: "s1", to: "B"),
                EmbeddingTestFixtures.resolvedEdge(from: "s2", to: "B"),
                EmbeddingTestFixtures.resolvedEdge(from: "s3", to: "B"),
            ],
            backlinks: [:],
            unresolvedLinks: [:],
            lastIndexedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testPureCosineRanksExactMatchFirst() async throws {
        let indexer = SemanticIndexer(provider: provider())
        let hits = try await indexer.search(
            query: query, in: embeddingIndex(), graph: graph(), topK: 3, centralityWeight: 0
        )
        XCTAssertEqual(hits.map(\.documentId), ["A", "B", "C"])
    }

    func testCentralityReRankPromotesWellConnectedNearTie() async throws {
        let indexer = SemanticIndexer(provider: provider())
        let hits = try await indexer.search(
            query: query, in: embeddingIndex(), graph: graph(), topK: 3
        ) // default centralityWeight 0.08
        // B's near-tie cosine + centrality boost overtakes A's exact match.
        XCTAssertEqual(hits.first?.documentId, "B")
        XCTAssertEqual(hits.map(\.documentId), ["B", "A", "C"])
    }

    func testTopKLimitsResults() async throws {
        let indexer = SemanticIndexer(provider: provider())
        let hits = try await indexer.search(query: query, in: embeddingIndex(), graph: graph(), topK: 1)
        XCTAssertEqual(hits.count, 1)
    }

    func testEmptyQueryReturnsNoHits() async throws {
        let indexer = SemanticIndexer(provider: provider())
        let hits = try await indexer.search(query: "   ", in: embeddingIndex(), graph: graph(), topK: 3)
        XCTAssertTrue(hits.isEmpty)
    }

    func testDegreesCountResolvedEdgesOnly() {
        let edges = [
            EmbeddingTestFixtures.resolvedEdge(from: "A", to: "B"),
            LinkEdge(id: "u", sourceId: "A", targetId: nil, href: "x", normalizedTargetPath: nil,
                     fragment: nil, linkText: "x", status: .unresolved),
        ]
        let g = EmbeddingTestFixtures.index(documents: [], edges: edges)
        let degrees = SemanticIndexer.degrees(in: g)
        XCTAssertEqual(degrees["A"], 1) // only the resolved A->B edge counts
        XCTAssertEqual(degrees["B"], 1)
    }
}
