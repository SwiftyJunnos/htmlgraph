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

        if trimmed.hasPrefix("//") {
            return NormalizedLink(targetPath: nil, fragment: nil, status: .external)
        }

        if let scheme = scheme(in: trimmed), scheme != "file" {
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

        guard !pathPart.isEmpty else {
            return NormalizedLink(targetPath: sourcePath, fragment: fragment, status: .sameDocument)
        }

        guard let decodedPathPart = pathPart.removingPercentEncoding,
              !decodedPathPart.contains("\0"),
              let relative = normalizedPath(decodedPathPart, sourcePath: sourcePath) else {
            return NormalizedLink(targetPath: nil, fragment: fragment, status: .unresolved)
        }

        let pathExtension = (relative as NSString).pathExtension.lowercased()
        guard pathExtension == "html" || pathExtension == "htm" else {
            return NormalizedLink(targetPath: relative, fragment: fragment, status: .unresolved)
        }

        let status: LinkStatus = knownDocumentIds.contains(relative) ? .resolved : .unresolved
        return NormalizedLink(targetPath: relative, fragment: fragment, status: status)
    }

    private func scheme(in href: String) -> String? {
        guard let colonIndex = href.firstIndex(of: ":") else { return nil }
        let prefix = href[..<colonIndex]
        guard !prefix.isEmpty else { return nil }

        let boundaryCharacters = CharacterSet(charactersIn: "/?#")
        if prefix.rangeOfCharacter(from: boundaryCharacters) != nil {
            return nil
        }

        guard let first = prefix.unicodeScalars.first, CharacterSet.letters.contains(first) else {
            return nil
        }

        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-.")
        guard prefix.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            return nil
        }

        return prefix.lowercased()
    }

    private func normalizedPath(_ path: String, sourcePath: String) -> String? {
        var components: [String] = []
        if !path.hasPrefix("/") {
            components = sourcePath.split(separator: "/").dropLast().map(String.init)
        }

        for component in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(component)
            }
        }

        return components.joined(separator: "/")
    }
}
