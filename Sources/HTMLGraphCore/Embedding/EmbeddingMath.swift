import Foundation

/// Pure vector math for semantic search. No dependencies, trivially testable.
public enum EmbeddingMath {
    /// Cosine similarity in `[-1, 1]`. Returns `0` when either vector is zero-length
    /// or has zero magnitude (so a degenerate vector never produces NaN).
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom == 0 ? 0 : dot / denom
    }

    /// Returns `v` scaled to unit L2 length. A zero vector is returned unchanged.
    public static func l2Normalized(_ v: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for x in v { sumSquares += x * x }
        let magnitude = sumSquares.squareRoot()
        guard magnitude > 0 else { return v }
        return v.map { $0 / magnitude }
    }

    /// Element-wise mean of equal-length vectors. Empty input ⇒ empty output.
    /// Used to pool per-chunk vectors into one document vector.
    public static func meanPooled(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        let dimension = first.count
        var accumulator = [Float](repeating: 0, count: dimension)
        var count = 0
        for vector in vectors where vector.count == dimension {
            for i in 0..<dimension { accumulator[i] += vector[i] }
            count += 1
        }
        guard count > 0 else { return [] }
        let divisor = Float(count)
        for i in 0..<dimension { accumulator[i] /= divisor }
        return accumulator
    }
}
