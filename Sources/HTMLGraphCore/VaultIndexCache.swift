import Foundation

public struct VaultIndexCache {
    public let rootURL: URL

    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func save(_ index: VaultIndex) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let data = try VaultIndexJSON.encoder.encode(index)
        try data.write(to: fileURL(for: index.vaultId), options: [.atomic])
    }

    public func load(vaultId: String) throws -> VaultIndex? {
        let url = fileURL(for: vaultId)

        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try VaultIndexJSON.decoder.decode(VaultIndex.self, from: data)
    }

    private func fileURL(for vaultId: String) -> URL {
        rootURL.appendingPathComponent(Self.cacheKey(for: vaultId)).appendingPathExtension("json")
    }

    private static func cacheKey(for vaultId: String) -> String {
        Data(vaultId.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
