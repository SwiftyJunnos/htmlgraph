import Foundation

enum HTMLDocumentNavigationDecision: Equatable {
    case allow
    case internalDocument(String)
    case external(URL)
    /// A subframe (or resource) tried to load remote content while the vault has
    /// network access turned off. Distinct from `.error` so the UI can offer to
    /// enable network access instead of showing a dead-end alert.
    case networkBlocked(URL)
    case error(String)
}

struct HTMLDocumentNavigationPolicy {
    let currentDocumentURL: URL
    let vaultURL: URL
    let knownDocumentIds: Set<String>
    var allowsNetworkAccess: Bool = false

    private static let networkSubframeSchemes: Set<String> = ["http", "https"]

    func decision(
        for targetURL: URL,
        isMainFrame: Bool,
        isUserInitiated: Bool
    ) -> HTMLDocumentNavigationDecision {
        // WebKit bootstraps every <iframe> by first committing about:blank (and
        // uses about:srcdoc for srcdoc frames) before loading the real src. These
        // carry no content and must always be allowed, or the embed never starts.
        if Self.isAboutBlankOrSrcdoc(targetURL) {
            return .allow
        }

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
        if targetURL.isFileURL {
            guard vaultRelativePath(for: targetURL, in: vaultURL) != nil else {
                return .error("Blocked subframe navigation outside the selected vault: \(targetURL.absoluteString)")
            }
            return .allow
        }

        // Network embeds (e.g. a YouTube <iframe>) need a trusted vault with
        // network access. When it's off, report it as a network block so the UI
        // can offer to turn it on rather than showing a dead-end error.
        if Self.networkSubframeSchemes.contains(targetURL.scheme?.lowercased() ?? "") {
            return allowsNetworkAccess ? .allow : .networkBlocked(targetURL)
        }

        return .error("Blocked subframe navigation outside the selected vault: \(targetURL.absoluteString)")
    }

    private static func isAboutBlankOrSrcdoc(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "about" else { return false }
        // Match only the exact bootstrap URLs WebKit emits — not a prefix family like
        // "about:srcdocEVIL". A trailing #fragment is the one variation WebKit may add.
        var value = url.absoluteString.lowercased()
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash])
        }
        return value == "about:blank" || value == "about:srcdoc"
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
