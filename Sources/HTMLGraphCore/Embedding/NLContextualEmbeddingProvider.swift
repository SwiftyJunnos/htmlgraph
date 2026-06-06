import Foundation
import NaturalLanguage

public enum EmbeddingProviderError: Error, Sendable {
    /// The on-device model's assets are not present and could not be downloaded
    /// (e.g. offline). Callers should fall back to lexical search.
    case assetsUnavailable
}

/// `EmbeddingProvider` backed by Apple's on-device `NLContextualEmbedding`.
///
/// Uses the multilingual model for the content's script — `.korean` selects the
/// CJK model (WWDC23-10042: one model covers Chinese/Japanese/Korean), which is the
/// only built-in Apple option that embeds Korean (`NLEmbedding.sentenceEmbedding`
/// returns `nil` for Korean). Available macOS 14+ — exactly the package floor — so
/// no `#available` guard is needed.
///
/// `NLContextualEmbedding` emits **per-token** vectors; we mean-pool them into one
/// document vector (Apple does not pool). Model assets download on demand the first
/// time `embed` runs (`hasAvailableAssets` → `requestAssets` → `load`), then work
/// offline. An actor so the lazy load and the underlying (non-`Sendable`) model are
/// serialized safely.
public actor NLContextualEmbeddingProvider: EmbeddingProvider {
    public nonisolated let identifier: String
    public nonisolated let dimension: Int

    private let language: NLLanguage
    private let model: NLContextualEmbedding
    private var didLoad = false

    /// Fails to initialize when the OS has no contextual model for `language`.
    public init?(language: NLLanguage = .korean, identifier: String = "nl-contextual.cjk.v1") {
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        self.model = model
        self.dimension = model.dimension
        self.language = language
        self.identifier = identifier
    }

    public func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [Float](repeating: 0, count: dimension) }

        try await ensureLoaded()

        let result = try model.embeddingResult(for: trimmed, language: language)
        var accumulator = [Double](repeating: 0, count: dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            let n = min(vector.count, accumulator.count)
            for i in 0..<n { accumulator[i] += vector[i] }
            tokenCount += 1
            return true
        }
        guard tokenCount > 0 else { return [Float](repeating: 0, count: dimension) }
        let divisor = Double(tokenCount)
        return accumulator.map { Float($0 / divisor) }
    }

    /// Whether the model's assets are already on disk (no download needed). Lets the
    /// app surface a "preparing…" state only when a download is actually pending.
    public var assetsAreAvailable: Bool {
        model.hasAvailableAssets
    }

    /// Downloads assets if needed and loads the model. Idempotent.
    public func prepare() async throws {
        try await ensureLoaded()
    }

    private func ensureLoaded() async throws {
        if didLoad { return }
        if !model.hasAvailableAssets {
            let result = try await model.requestAssets()
            guard result == .available else { throw EmbeddingProviderError.assetsUnavailable }
        }
        try model.load()
        didLoad = true
    }
}
