import Foundation

public struct VaultIndex: Codable, Equatable, Sendable {
    public let vaultId: String
    public let documents: [DocumentNode]
    public let edges: [LinkEdge]
    public let backlinks: [String: [LinkEdge]]
    public let unresolvedLinks: [String: [LinkEdge]]
    public let lastIndexedAt: Date

    public init(
        vaultId: String,
        documents: [DocumentNode],
        edges: [LinkEdge],
        backlinks: [String: [LinkEdge]],
        unresolvedLinks: [String: [LinkEdge]],
        lastIndexedAt: Date
    ) {
        self.vaultId = vaultId
        self.documents = documents
        self.edges = edges
        self.backlinks = backlinks
        self.unresolvedLinks = unresolvedLinks
        self.lastIndexedAt = lastIndexedAt
    }

    public func document(id: String) -> DocumentNode? {
        documents.first { $0.id == id }
    }
}
