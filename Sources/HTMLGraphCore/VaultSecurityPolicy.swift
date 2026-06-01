import Foundation

public enum VaultTrustMode: String, Codable, Equatable, Sendable {
    case safe
    case trusted
}

public struct VaultSecurityPolicy: Codable, Equatable, Sendable {
    public let mode: VaultTrustMode
    public let allowsNetworkAccess: Bool

    public var allowsJavaScript: Bool {
        mode == .trusted
    }

    public init(mode: VaultTrustMode, allowsNetworkAccess: Bool) {
        self.mode = mode
        self.allowsNetworkAccess = allowsNetworkAccess
    }

    public func allows(_ resourceURL: URL, vaultRoot: URL) -> Bool {
        guard resourceURL.isFileURL else {
            return allowsNetworkAccess && Self.networkSchemes.contains(resourceURL.scheme?.lowercased() ?? "")
        }

        let resourceComponents = resourceURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let vaultComponents = vaultRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents

        guard resourceComponents.count >= vaultComponents.count else {
            return false
        }

        return zip(vaultComponents, resourceComponents).allSatisfy { $0 == $1 }
    }

    private static let networkSchemes: Set<String> = ["http", "https"]
}
