import Foundation

public enum LinkStatus: String, Codable, Equatable, Hashable {
    case resolved
    case unresolved
    case sameDocument
    case external
}

public struct RawHTMLLink: Equatable, Hashable {
    public let href: String
    public let text: String

    public init(href: String, text: String) {
        self.href = href
        self.text = text
    }
}

public struct LinkEdge: Codable, Equatable, Identifiable, Hashable {
    public var id: String { "\(sourceId)->\(href)" }
    public let sourceId: String
    public let targetId: String?
    public let href: String
    public let normalizedTargetPath: String?
    public let fragment: String?
    public let linkText: String
    public let status: LinkStatus

    public init(
        sourceId: String,
        targetId: String?,
        href: String,
        normalizedTargetPath: String?,
        fragment: String?,
        linkText: String,
        status: LinkStatus
    ) {
        self.sourceId = sourceId
        self.targetId = targetId
        self.href = href
        self.normalizedTargetPath = normalizedTargetPath
        self.fragment = fragment
        self.linkText = linkText
        self.status = status
    }
}
