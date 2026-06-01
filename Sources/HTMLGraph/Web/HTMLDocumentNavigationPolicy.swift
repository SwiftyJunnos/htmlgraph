import Foundation

enum HTMLDocumentNavigationDecision: Equatable {
    case allow
    case internalDocument(String)
    case external(URL)
    case error(String)
}

struct HTMLDocumentNavigationPolicy {
    let currentDocumentURL: URL
    let vaultURL: URL
    let knownDocumentIds: Set<String>

    func decision(for targetURL: URL, isMainFrame: Bool) -> HTMLDocumentNavigationDecision {
        guard isMainFrame else { return .allow }

        guard targetURL.isFileURL else {
            return .external(targetURL)
        }

        guard let relativePath = vaultRelativePath(for: targetURL, in: vaultURL) else {
            return .external(targetURL)
        }

        if relativePath == vaultRelativePath(for: currentDocumentURL, in: vaultURL) {
            return .allow
        }

        guard knownDocumentIds.contains(relativePath) else {
            return .error("Cannot navigate to unindexed vault file: \(relativePath)")
        }

        return .internalDocument(relativePath)
    }

    private func vaultRelativePath(for fileURL: URL, in vaultURL: URL) -> String? {
        let fileComponents = fileURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let vaultComponents = vaultURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents

        guard fileComponents.count > vaultComponents.count else { return nil }
        guard zip(vaultComponents, fileComponents).allSatisfy({ $0 == $1 }) else { return nil }

        return fileComponents
            .dropFirst(vaultComponents.count)
            .joined(separator: "/")
    }
}
