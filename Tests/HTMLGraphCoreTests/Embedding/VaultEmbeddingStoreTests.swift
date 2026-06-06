import XCTest
@testable import HTMLGraphCore

final class VaultEmbeddingStoreTests: XCTestCase {
    private var vaultURL: URL!

    override func setUpWithError() throws {
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("embstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultURL)
    }

    func testBase64Float32RoundTripIsExact() {
        let vector: [Float] = [0, 1, -1, .pi, -.greatestFiniteMagnitude, 1e-30, 12345.6789]
        let encoded = VaultEmbeddingStore.encodeVector(vector)
        let decoded = VaultEmbeddingStore.decodeVector(encoded, dimension: vector.count)
        XCTAssertEqual(decoded, vector) // exact: same bit pattern round-trips
    }

    func testDecodeRejectsWrongDimension() {
        let encoded = VaultEmbeddingStore.encodeVector([1, 2, 3])
        XCTAssertNil(VaultEmbeddingStore.decodeVector(encoded, dimension: 4))
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = VaultEmbeddingStore()
        let records = [
            "doc-a": EmbeddingRecord(contentHash: "hash-a", vector: [1, 0, 0, 0]),
            "doc-b": EmbeddingRecord(contentHash: "hash-b", vector: [0, 1, 0, 0]),
        ]
        try store.save(records, providerId: "p.v1", dimension: 4, vaultURL: vaultURL)

        let loaded = store.load(providerId: "p.v1", dimension: 4, vaultURL: vaultURL)
        XCTAssertEqual(loaded, records)
    }

    func testWritesToHiddenSidecarPath() throws {
        let store = VaultEmbeddingStore()
        try store.save(["d": EmbeddingRecord(contentHash: "h", vector: [1, 0])],
                       providerId: "p", dimension: 2, vaultURL: vaultURL)
        let expected = vaultURL
            .appendingPathComponent(".htmlgraph", isDirectory: true)
            .appendingPathComponent("embeddings.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testProviderIdMismatchDiscardsCache() throws {
        let store = VaultEmbeddingStore()
        try store.save(["d": EmbeddingRecord(contentHash: "h", vector: [1, 0])],
                       providerId: "old.v1", dimension: 2, vaultURL: vaultURL)
        XCTAssertNil(store.load(providerId: "new.v2", dimension: 2, vaultURL: vaultURL))
    }

    func testDimensionMismatchDiscardsCache() throws {
        let store = VaultEmbeddingStore()
        try store.save(["d": EmbeddingRecord(contentHash: "h", vector: [1, 0])],
                       providerId: "p", dimension: 2, vaultURL: vaultURL)
        XCTAssertNil(store.load(providerId: "p", dimension: 512, vaultURL: vaultURL))
    }

    func testLoadMissingFileReturnsNil() {
        let store = VaultEmbeddingStore()
        XCTAssertNil(store.load(providerId: "p", dimension: 2, vaultURL: vaultURL))
    }
}
