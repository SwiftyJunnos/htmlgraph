import Foundation

/// The on-disk envelope for an exported vault graph.
///
/// `schemaVersion` is encoded as a top-level sibling of the `VaultIndex` fields
/// (`documents`, `edges`, `backlinks`, …) rather than nesting the index, so AI
/// tools can read a flat, self-describing document and branch on the version.
/// `VaultIndex` itself is left untouched — the flat shape is produced by this
/// type's custom `Codable` conformance.
public struct ExportedGraph: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let index: VaultIndex

    public init(schemaVersion: Int, index: VaultIndex) {
        self.schemaVersion = schemaVersion
        self.index = index
    }

    // These cases (apart from `schemaVersion`) must mirror `VaultIndex`'s stored
    // properties one-for-one — the flat shape is produced by hand below, so a new
    // `VaultIndex` field will be silently dropped from `graph.json` until it is
    // added here too. `VaultIndexExporterTests.testExportedKeysCoverAllVaultIndexFields`
    // guards against that drift by reflecting over `VaultIndex`.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case vaultId
        case documents
        case edges
        case backlinks
        case unresolvedLinks
        case lastIndexedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(index.vaultId, forKey: .vaultId)
        try container.encode(index.documents, forKey: .documents)
        try container.encode(index.edges, forKey: .edges)
        try container.encode(index.backlinks, forKey: .backlinks)
        try container.encode(index.unresolvedLinks, forKey: .unresolvedLinks)
        try container.encode(index.lastIndexedAt, forKey: .lastIndexedAt)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        index = VaultIndex(
            vaultId: try container.decode(String.self, forKey: .vaultId),
            documents: try container.decode([DocumentNode].self, forKey: .documents),
            edges: try container.decode([LinkEdge].self, forKey: .edges),
            backlinks: try container.decode([String: [LinkEdge]].self, forKey: .backlinks),
            unresolvedLinks: try container.decode([String: [LinkEdge]].self, forKey: .unresolvedLinks),
            lastIndexedAt: try container.decode(Date.self, forKey: .lastIndexedAt)
        )
    }
}

/// Writes the computed vault graph to a stable, machine-readable sidecar so
/// external AI tools can consume the relationships HTMLGraph already computes
/// (documents, edges, backlinks, unresolved links) without re-parsing the HTML.
///
/// The artifact lands at `<vault>/.htmlgraph/graph.json` — discoverable right
/// next to the notes. The directory is hidden, so `VaultIndexer` (which enumerates
/// with `.skipsHiddenFiles` and only ingests `.html`/`.htm`) never re-indexes it:
/// there is no feedback loop.
///
/// Notes:
/// - The loopback preview server (`VaultHTTPServer`) will also serve this file at
///   `<token>/.htmlgraph/graph.json`. That is an intentional, accepted exposure —
///   the server is loopback-only with a random per-session token — and is arguably
///   useful for local AI tooling.
/// - The exported JSON embeds machine-local absolute paths (`vaultId`,
///   `DocumentNode.absolutePath`). It is a local artifact, not a portable one; a
///   future schema version may relativize these.
public struct VaultIndexExporter {
    public static let directoryName = ".htmlgraph"
    public static let fileName = "graph.json"
    public static let schemaVersion = 1

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The directory the sidecar is written into for a given vault.
    public static func sidecarDirectory(forVault vaultURL: URL) -> URL {
        vaultURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The full path of the exported graph file for a given vault.
    public static func graphFileURL(forVault vaultURL: URL) -> URL {
        sidecarDirectory(forVault: vaultURL).appendingPathComponent(fileName)
    }

    /// Writes `<vault>/.htmlgraph/graph.json` atomically. Returns the file URL.
    @discardableResult
    public func export(_ index: VaultIndex, vaultURL: URL) throws -> URL {
        let directory = Self.sidecarDirectory(forVault: vaultURL)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent(Self.fileName)
        let payload = ExportedGraph(schemaVersion: Self.schemaVersion, index: index)
        let data = try VaultIndexJSON.interoperableEncoder.encode(payload)
        try data.write(to: fileURL, options: [.atomic])

        return fileURL
    }
}
