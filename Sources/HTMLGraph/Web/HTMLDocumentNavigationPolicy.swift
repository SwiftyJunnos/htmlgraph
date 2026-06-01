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

    func decision(
        for targetURL: URL,
        isMainFrame: Bool,
        isUserInitiated: Bool
    ) -> HTMLDocumentNavigationDecision {
        guard isMainFrame else {
            return subframeDecision(for: targetURL)
        }

        guard targetURL.isFileURL else {
            return externalDecision(for: targetURL, isUserInitiated: isUserInitiated)
        }

        guard let relativePath = vaultRelativePath(for: targetURL, in: vaultURL) else {
            return externalDecision(for: targetURL, isUserInitiated: isUserInitiated)
        }

        if relativePath == vaultRelativePath(for: currentDocumentURL, in: vaultURL) {
            return .allow
        }

        guard knownDocumentIds.contains(relativePath) else {
            return .error("Cannot navigate to unindexed vault file: \(relativePath)")
        }

        return .internalDocument(relativePath)
    }

    private func subframeDecision(for targetURL: URL) -> HTMLDocumentNavigationDecision {
        guard targetURL.isFileURL, vaultRelativePath(for: targetURL, in: vaultURL) != nil else {
            return .error("Blocked subframe navigation outside the selected vault: \(targetURL.absoluteString)")
        }

        return .allow
    }

    private func externalDecision(
        for targetURL: URL,
        isUserInitiated: Bool
    ) -> HTMLDocumentNavigationDecision {
        if isUserInitiated {
            return .external(targetURL)
        }

        return .error("Blocked non-user-initiated external navigation: \(targetURL.absoluteString)")
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
