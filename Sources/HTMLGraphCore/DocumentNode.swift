import Foundation

public struct DocumentNode: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let path: String
    public let absolutePath: String
    public let title: String
    public let contentHash: String
    public let lastModified: Date

    public init(
        id: String,
        path: String,
        absolutePath: String,
        title: String,
        contentHash: String,
        lastModified: Date
    ) {
        self.id = id
        self.path = path
        self.absolutePath = absolutePath
        self.title = title
        self.contentHash = contentHash
        self.lastModified = lastModified
    }
}
