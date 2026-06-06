import XCTest
@testable import HTMLGraphCore

final class EmbeddingMathTests: XCTestCase {
    func testIdenticalVectorsHaveCosineOne() {
        let v: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(EmbeddingMath.cosineSimilarity(v, v), 1, accuracy: 1e-6)
    }

    func testOrthogonalVectorsHaveCosineZero() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 1e-6)
    }

    func testOppositeVectorsHaveCosineMinusOne() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 1], [-1, -1]), -1, accuracy: 1e-6)
    }

    func testCosineIsScaleInvariant() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [10, 20, 30]
        XCTAssertEqual(EmbeddingMath.cosineSimilarity(a, b), 1, accuracy: 1e-6)
    }

    func testZeroVectorCosineIsZeroNotNaN() {
        let s = EmbeddingMath.cosineSimilarity([0, 0, 0], [1, 2, 3])
        XCTAssertFalse(s.isNaN)
        XCTAssertEqual(s, 0)
    }

    func testMismatchedLengthsCosineIsZero() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 2], [1, 2, 3]), 0)
    }

    func testL2NormalizedHasUnitMagnitude() {
        let n = EmbeddingMath.l2Normalized([3, 4])
        XCTAssertEqual(n[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(n[1], 0.8, accuracy: 1e-6)
        let mag = (n[0] * n[0] + n[1] * n[1]).squareRoot()
        XCTAssertEqual(mag, 1, accuracy: 1e-6)
    }

    func testL2NormalizeZeroVectorIsUnchanged() {
        XCTAssertEqual(EmbeddingMath.l2Normalized([0, 0, 0]), [0, 0, 0])
    }

    func testMeanPooledAveragesElementwise() {
        let pooled = EmbeddingMath.meanPooled([[1, 2], [3, 4], [5, 6]])
        XCTAssertEqual(pooled, [3, 4])
    }

    func testMeanPooledEmptyInputIsEmpty() {
        XCTAssertEqual(EmbeddingMath.meanPooled([]), [])
    }

    func testMeanPooledSkipsMismatchedLengthVectors() {
        // The odd-length vector is ignored; pooling is over the two [1,1]/[3,3].
        let pooled = EmbeddingMath.meanPooled([[1, 1], [3, 3], [9, 9, 9]])
        XCTAssertEqual(pooled, [2, 2])
    }

    func testKnownTripleOrders() {
        // a closer to b than to c.
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0.9, 0.1, 0]
        let c: [Float] = [0, 0, 1]
        XCTAssertGreaterThan(
            EmbeddingMath.cosineSimilarity(a, b),
            EmbeddingMath.cosineSimilarity(a, c)
        )
    }
}
