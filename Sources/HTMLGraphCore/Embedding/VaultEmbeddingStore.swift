import Foundation

/// One persisted document embedding: the `contentHash` it was computed from (the
/// cache key, alongside the docId) and the vector itself.
public struct EmbeddingRecord: Equatable, Sendable {
    public let contentHash: String
    public let vector: [Float]

    public init(contentHash: String, vector: [Float]) {
        self.contentHash = contentHash
        self.vector = vector
    }
}

/// Persists per-document embedding vectors to a hidden sidecar
/// `<vault>/.htmlgraph/embeddings.json`, alongside `graph.json`.
///
/// Deliberately a **separate** file from `graph.json`: the `ExportedGraph`
/// `schemaVersion=1` contract stays untouched, and the indexer's
/// `.skipsHiddenFiles` enumeration means this file is never re-ingested.
///
/// On-disk envelope:
/// ```json
/// { "schemaVersion": 1, "providerId": "...", "dimension": 512,
///   "entries": { "<docId>": { "contentHash": "...", "vector": "<base64 LE f32>" } } }
/// ```
/// Vectors are stored as base64 of little-endian `Float32` — compact and exact
/// (no JSON float round-trip loss). If `schemaVersion`, `providerId`, or `dimension`
/// don't match what the caller expects, the whole file is discarded (returns `nil`),
/// forcing a rebuild — vectors from a different model/schema are not comparable.
public struct VaultEmbeddingStore: Sendable {
    public static let schemaVersion = 1
    public static let fileName = "embeddings.json"

    /// Vault-relative location of the sidecar (`.htmlgraph/embeddings.json`) — the address
    /// passed to a `VaultFileSystem`, reusing the graph sidecar directory.
    public static let relativePath = "\(VaultIndexExporter.directoryName)/\(fileName)"

    public init() {}

    /// `<vault>/.htmlgraph/embeddings.json` — the on-disk location for a local vault.
    public static func fileURL(forVault vaultURL: URL) -> URL {
        VaultIndexExporter.sidecarDirectory(forVault: vaultURL)
            .appendingPathComponent(fileName)
    }

    /// Loads persisted records for `(providerId, dimension)`. Returns `nil` when the
    /// file is absent, unreadable, or its `schemaVersion`/`providerId`/`dimension`
    /// don't match (⇒ caller rebuilds from scratch).
    public func load(providerId: String, dimension: Int, fileSystem: VaultFileSystem) async -> [String: EmbeddingRecord]? {
        guard let data = try? await fileSystem.readData(at: Self.relativePath),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return nil
        }
        guard envelope.schemaVersion == Self.schemaVersion,
              envelope.providerId == providerId,
              envelope.dimension == dimension else {
            return nil
        }
        var records: [String: EmbeddingRecord] = [:]
        records.reserveCapacity(envelope.entries.count)
        for (docId, entry) in envelope.entries {
            guard let vector = Self.decodeVector(entry.vector, dimension: dimension) else {
                // A single corrupt entry shouldn't poison the whole cache; skip it
                // (it'll be re-embedded because it's now missing for its docId).
                continue
            }
            records[docId] = EmbeddingRecord(contentHash: entry.contentHash, vector: vector)
        }
        return records
    }

    /// Atomically writes `records` to the sidecar.
    public func save(
        _ records: [String: EmbeddingRecord],
        providerId: String,
        dimension: Int,
        fileSystem: VaultFileSystem
    ) async throws {
        let entries = records.mapValues {
            Entry(contentHash: $0.contentHash, vector: Self.encodeVector($0.vector))
        }
        let envelope = Envelope(
            schemaVersion: Self.schemaVersion,
            providerId: providerId,
            dimension: dimension,
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)

        try await fileSystem.createDirectory(at: VaultIndexExporter.directoryName)
        try await fileSystem.writeData(data, to: Self.relativePath, options: [.atomic])
    }

    // MARK: - Codable envelope

    private struct Envelope: Codable {
        let schemaVersion: Int
        let providerId: String
        let dimension: Int
        let entries: [String: Entry]
    }

    private struct Entry: Codable {
        let contentHash: String
        let vector: String // base64 of little-endian Float32
    }

    // MARK: - Vector <-> base64 (little-endian Float32)

    static func encodeVector(_ vector: [Float]) -> String {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var littleEndianBits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndianBits) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }

    static func decodeVector(_ base64: String, dimension: Int) -> [Float]? {
        guard let data = Data(base64Encoded: base64), data.count == dimension * 4 else {
            return nil
        }
        var vector = [Float]()
        vector.reserveCapacity(dimension)
        var index = data.startIndex
        for _ in 0..<dimension {
            let b0 = UInt32(data[index])
            let b1 = UInt32(data[index + 1])
            let b2 = UInt32(data[index + 2])
            let b3 = UInt32(data[index + 3])
            let bits = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            vector.append(Float(bitPattern: bits))
            index += 4
        }
        return vector
    }
}
