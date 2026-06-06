import XCTest
import NaturalLanguage
@testable import HTMLGraphCore

/// Integration test for the real on-device provider. Guards the
/// `NLEmbedding.sentenceEmbedding`-returns-nil-for-Korean trap (guardrail #7):
/// `NLContextualEmbedding` must return a finite, full-dimension vector for Korean.
/// Skips when the model or its assets aren't available (e.g. offline CI).
final class NLContextualEmbeddingProviderTests: XCTestCase {
    func testReturnsFiniteFullDimensionVectorForKorean() async throws {
        guard let provider = NLContextualEmbeddingProvider() else {
            throw XCTSkip("No NLContextualEmbedding model for Korean on this OS.")
        }
        do {
            try await provider.prepare()
        } catch EmbeddingProviderError.assetsUnavailable {
            throw XCTSkip("Korean embedding assets unavailable (offline?).")
        }

        let dimension = provider.dimension
        XCTAssertGreaterThan(dimension, 0)

        let vector = try await provider.embed("의미 기반 검색을 위한 한국어 문장입니다.")
        XCTAssertEqual(vector.count, dimension)
        XCTAssertTrue(vector.allSatisfy { $0.isFinite }, "Vector must be finite (the nil-Korean trap)")
        XCTAssertTrue(vector.contains { $0 != 0 }, "Vector must not be all zeros for real Korean text")
    }

    func testEmptyInputReturnsZeroVectorWithoutLoadingAssets() async throws {
        guard let provider = NLContextualEmbeddingProvider() else {
            throw XCTSkip("No NLContextualEmbedding model for Korean on this OS.")
        }
        let vector = try await provider.embed("   ")
        XCTAssertEqual(vector, [Float](repeating: 0, count: provider.dimension))
    }
}
