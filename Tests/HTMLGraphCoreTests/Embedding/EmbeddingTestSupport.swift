import Foundation
@testable import HTMLGraphCore

/// Wraps a `DeterministicEmbeddingProvider` and records every text it embeds, so
/// tests can assert which documents were (or were not) re-embedded. Thread-safe.
final class RecordingEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    let identifier: String
    let dimension: Int
    private let backing: DeterministicEmbeddingProvider
    private let lock = NSLock()
    private var _embeddedTexts: [String] = []

    init(identifier: String = "recording.v1", dimension: Int = 8) {
        self.identifier = identifier
        self.dimension = dimension
        self.backing = DeterministicEmbeddingProvider(identifier: identifier, dimension: dimension)
    }

    func embed(_ text: String) async throws -> [Float] {
        record(text)
        return try await backing.embed(text)
    }

    private func record(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        _embeddedTexts.append(text)
    }

    /// Texts embedded so far, then clears the record.
    func drainEmbeddedTexts() -> [String] {
        lock.lock()
        defer { _embeddedTexts.removeAll(); lock.unlock() }
        return _embeddedTexts
    }
}

/// Returns a fixed vector for each exact input string (zero vector otherwise).
/// For deterministic ranking tests where vectors must be hand-chosen.
struct FixedEmbeddingProvider: EmbeddingProvider {
    let identifier: String
    let dimension: Int
    let vectors: [String: [Float]]

    init(identifier: String = "fixed.v1", dimension: Int, vectors: [String: [Float]]) {
        self.identifier = identifier
        self.dimension = dimension
        self.vectors = vectors
    }

    func embed(_ text: String) async throws -> [Float] {
        vectors[text] ?? [Float](repeating: 0, count: dimension)
    }
}

enum EmbeddingTestFixtures {
    static func document(id: String, title: String, contentHash: String) -> DocumentNode {
        DocumentNode(
            id: id,
            path: "\(id).html",
            absolutePath: "/tmp/\(id).html",
            title: title,
            contentHash: contentHash,
            lastModified: Date(timeIntervalSince1970: 0)
        )
    }

    static func index(documents: [DocumentNode], edges: [LinkEdge] = []) -> VaultIndex {
        VaultIndex(
            vaultId: "test-vault",
            documents: documents,
            edges: edges,
            backlinks: [:],
            unresolvedLinks: [:],
            lastIndexedAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func resolvedEdge(from sourceId: String, to targetId: String) -> LinkEdge {
        LinkEdge(
            id: "\(sourceId)->\(targetId)",
            sourceId: sourceId,
            targetId: targetId,
            href: "\(targetId).html",
            normalizedTargetPath: "\(targetId).html",
            fragment: nil,
            linkText: targetId,
            status: .resolved
        )
    }
}
