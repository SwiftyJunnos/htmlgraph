import Foundation

public struct NormalizedLink: Equatable {
    public let targetPath: String?
    public let fragment: String?
    public let status: LinkStatus

    public init(targetPath: String?, fragment: String?, status: LinkStatus) {
        self.targetPath = targetPath
        self.fragment = fragment
        self.status = status
    }
}

public struct LinkNormalizer {
    public init() {}

    public func normalize(href: String, sourcePath: String, knownDocumentIds: Set<String>) -> NormalizedLink {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return NormalizedLink(targetPath: nil, fragment: nil, status: .unresolved)
        }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("mailto:") {
            return NormalizedLink(targetPath: nil, fragment: nil, status: .external)
        }

        if trimmed.hasPrefix("#") {
            return NormalizedLink(
                targetPath: sourcePath,
                fragment: String(trimmed.dropFirst()),
                status: .sameDocument
            )
        }

        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let pathPart = String(parts[0])
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        let fragment = parts.count > 1 ? String(parts[1]) : nil

        let sourceDirectory = (sourcePath as NSString).deletingLastPathComponent
        let joined = sourceDirectory.isEmpty ? pathPart : "\(sourceDirectory)/\(pathPart)"
        let relative = (joined as NSString).standardizingPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard relative.hasSuffix(".html") || relative.hasSuffix(".htm") else {
            return NormalizedLink(targetPath: relative, fragment: fragment, status: .unresolved)
        }

        let status: LinkStatus = knownDocumentIds.contains(relative) ? .resolved : .unresolved
        return NormalizedLink(targetPath: relative, fragment: fragment, status: status)
    }
}
