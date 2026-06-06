import Foundation

/// Produces a dense vector embedding for a piece of text.
///
/// The protocol is the seam that lets the OS-backed `NLContextualEmbedding`
/// implementation (Phase 0.2) be swapped for a Core ML model later (Phase 1)
/// without touching `SemanticIndexer`, and lets unit tests inject a deterministic
/// fake instead of the (asset-downloading, OS-version-dependent) real model.
///
/// `identifier` and `dimension` are part of the on-disk cache contract: if either
/// changes, `VaultEmbeddingStore` discards the persisted vectors and forces a
/// rebuild (vectors from different models are not comparable).
public protocol EmbeddingProvider: Sendable {
    /// Stable identity of the model + pooling strategy (e.g. `"nl-contextual.cjk.v1"`).
    /// A change here invalidates every persisted vector.
    var identifier: String { get }

    /// Length of every vector this provider returns.
    var dimension: Int { get }

    /// Embed `text` into a `dimension`-length vector. Implementations should return
    /// a finite vector; callers normalize/pool as needed.
    func embed(_ text: String) async throws -> [Float]
}

/// A pure, hash-seeded fake provider for tests and as a last-resort offline
/// fallback. The same input string always yields the same L2-normalized vector
/// (across processes and machines — it does NOT use `Swift.Hasher`, which is
/// per-process randomized), so tests can assert stable cosine relationships and
/// cache hit/miss behavior. It carries **no semantic meaning** — unrelated strings
/// get unrelated vectors — so it is only for exercising the plumbing, never for
/// judging retrieval quality.
public struct DeterministicEmbeddingProvider: EmbeddingProvider {
    public let identifier: String
    public let dimension: Int

    public init(identifier: String = "deterministic.fnv.v1", dimension: Int = 512) {
        precondition(dimension > 0, "dimension must be positive")
        self.identifier = identifier
        self.dimension = dimension
    }

    public func embed(_ text: String) async throws -> [Float] {
        // Seed a SplitMix64 stream from a stable FNV-1a hash of the UTF-8 bytes.
        var state = Self.fnv1a(text)
        var raw = [Float](repeating: 0, count: dimension)
        for i in 0..<dimension {
            state = Self.splitmix64(state)
            // Map to [-1, 1) deterministically.
            let unit = Double(state >> 11) * (1.0 / 9007199254740992.0) // 2^-53, in [0,1)
            raw[i] = Float(unit * 2.0 - 1.0)
        }
        return EmbeddingMath.l2Normalized(raw)
    }

    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // Avoid an all-zero seed (degenerate for splitmix64's first step is fine,
        // but keep it non-zero for clarity).
        return hash == 0 ? 0x9e3779b97f4a7c15 : hash
    }

    private static func splitmix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
