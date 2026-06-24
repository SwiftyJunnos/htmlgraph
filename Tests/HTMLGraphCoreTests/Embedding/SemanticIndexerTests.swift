import XCTest
@testable import HTMLGraphCore

final class SemanticIndexerTests: XCTestCase {
    private var vaultURL: URL!

    override func setUpWithError() throws {
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("semidx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultURL)
    }

    private func makeIndexer(_ recorder: RecordingEmbeddingProvider, bodies: [String: String]) -> SemanticIndexer {
        SemanticIndexer(
            provider: recorder,
            maxCharsPerChunk: EmbeddingInput.defaultMaxCharsPerChunk,
            bodyTextLoader: { node, _ in bodies[node.id] ?? "" }
        )
    }

    func testUnchangedDocumentsAreNotReEmbedded() async throws {
        let recorder = RecordingEmbeddingProvider()
        let indexer = makeIndexer(recorder, bodies: ["a": "내용 A", "b": "내용 B"])
        let docs = [
            EmbeddingTestFixtures.document(id: "a", title: "제목A", contentHash: "h1"),
            EmbeddingTestFixtures.document(id: "b", title: "제목B", contentHash: "h2"),
        ]
        let index = EmbeddingTestFixtures.index(documents: docs)

        _ = try await indexer.refresh(index: index, fileSystem: LocalFileSystem(root: vaultURL))
        XCTAssertEqual(recorder.drainEmbeddedTexts().count, 2, "Both docs embedded on first build")

        _ = try await indexer.refresh(index: index, fileSystem: LocalFileSystem(root: vaultURL))
        XCTAssertEqual(recorder.drainEmbeddedTexts().count, 0, "Unchanged docs reused from store")
    }

    func testChangedContentHashReEmbedsOnlyThatDocument() async throws {
        let recorder = RecordingEmbeddingProvider()
        let indexer = makeIndexer(recorder, bodies: ["a": "내용 A", "b": "내용 B"])
        let v1 = EmbeddingTestFixtures.index(documents: [
            EmbeddingTestFixtures.document(id: "a", title: "제목A", contentHash: "h1"),
            EmbeddingTestFixtures.document(id: "b", title: "제목B", contentHash: "h2"),
        ])
        _ = try await indexer.refresh(index: v1, fileSystem: LocalFileSystem(root: vaultURL))
        _ = recorder.drainEmbeddedTexts()

        let v2 = EmbeddingTestFixtures.index(documents: [
            EmbeddingTestFixtures.document(id: "a", title: "제목A", contentHash: "h1-CHANGED"),
            EmbeddingTestFixtures.document(id: "b", title: "제목B", contentHash: "h2"),
        ])
        _ = try await indexer.refresh(index: v2, fileSystem: LocalFileSystem(root: vaultURL))

        let embedded = recorder.drainEmbeddedTexts()
        XCTAssertEqual(embedded.count, 1)
        XCTAssertTrue(embedded[0].contains("내용 A"), "Only the changed doc 'a' is re-embedded")
    }

    func testGhostDocumentsArePruned() async throws {
        let recorder = RecordingEmbeddingProvider()
        let indexer = makeIndexer(recorder, bodies: ["a": "내용 A", "b": "내용 B"])
        let withBoth = EmbeddingTestFixtures.index(documents: [
            EmbeddingTestFixtures.document(id: "a", title: "제목A", contentHash: "h1"),
            EmbeddingTestFixtures.document(id: "b", title: "제목B", contentHash: "h2"),
        ])
        _ = try await indexer.refresh(index: withBoth, fileSystem: LocalFileSystem(root: vaultURL))

        let withoutB = EmbeddingTestFixtures.index(documents: [
            EmbeddingTestFixtures.document(id: "a", title: "제목A", contentHash: "h1"),
        ])
        let result = try await indexer.refresh(index: withoutB, fileSystem: LocalFileSystem(root: vaultURL))

        XCTAssertNotNil(result.entries["a"])
        XCTAssertNil(result.entries["b"], "Ghost doc pruned from in-memory index")

        let persisted = await VaultEmbeddingStore().load(
            providerId: recorder.identifier, dimension: recorder.dimension, fileSystem: LocalFileSystem(root: vaultURL)
        )
        XCTAssertNil(persisted?["b"], "Ghost doc pruned from the sidecar too")
    }

    func testFullRefreshEqualsIncrementalRefreshForSameFinalState() async throws {
        let bodies = ["a": "내용 A", "b": "내용 B"]
        let docA = EmbeddingTestFixtures.document(id: "a", title: "제목A", contentHash: "h1")
        let docB = EmbeddingTestFixtures.document(id: "b", title: "제목B", contentHash: "h2")
        let finalIndex = EmbeddingTestFixtures.index(documents: [docA, docB])

        // Path 1: one full refresh in a fresh vault.
        let fullVault = vaultURL.appendingPathComponent("full", isDirectory: true)
        try FileManager.default.createDirectory(at: fullVault, withIntermediateDirectories: true)
        let fullIndexer = makeIndexer(RecordingEmbeddingProvider(), bodies: bodies)
        let full = try await fullIndexer.refresh(index: finalIndex, fileSystem: LocalFileSystem(root: fullVault))

        // Path 2: incremental — build with A only, then add B, in another vault.
        let incVault = vaultURL.appendingPathComponent("inc", isDirectory: true)
        try FileManager.default.createDirectory(at: incVault, withIntermediateDirectories: true)
        let incIndexer = makeIndexer(RecordingEmbeddingProvider(), bodies: bodies)
        _ = try await incIndexer.refresh(index: EmbeddingTestFixtures.index(documents: [docA]), fileSystem: LocalFileSystem(root: incVault))
        let incremental = try await incIndexer.refresh(index: finalIndex, fileSystem: LocalFileSystem(root: incVault))

        XCTAssertEqual(full.entries, incremental.entries, "Vectors are path-independent for the same final state")
    }

    func testDiskBodyTextLoaderEmbedsRealHTMLFile() async throws {
        let fileURL = vaultURL.appendingPathComponent("note.html")
        try "<html><body><h1>제목</h1><p>의미 기반 검색 본문</p></body></html>"
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let provider = DeterministicEmbeddingProvider(dimension: 16)
        let indexer = SemanticIndexer(provider: provider) // default disk loader
        let doc = DocumentNode(
            id: "note", path: "note.html", absolutePath: fileURL.path,
            title: "제목", contentHash: "h1", lastModified: Date(timeIntervalSince1970: 0)
        )
        let result = try await indexer.refresh(
            index: EmbeddingTestFixtures.index(documents: [doc]), fileSystem: LocalFileSystem(root: vaultURL)
        )

        let vector = try XCTUnwrap(result.entries["note"]?.vector)
        XCTAssertEqual(vector.count, 16)
        XCTAssertTrue(vector.allSatisfy { $0.isFinite })
    }
}
