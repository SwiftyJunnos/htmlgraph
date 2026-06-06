import Foundation

/// Builds the text actually fed to the embedding model from a document's title and
/// body text, and splits long documents into chunks.
///
/// `NLContextualEmbedding` has a bounded context window, so a long note must be
/// chunked and the per-chunk vectors mean-pooled (see `SemanticIndexer`). We don't
/// have the model's tokenizer here, so chunk size is expressed in characters as a
/// conservative proxy for "~256 tokens": Korean/CJK is ~1 char/token while Latin is
/// ~4 chars/token, so a ~1000-char cap stays comfortably inside the window for
/// mixed Korean/English prose. The title is prepended so it always lands in the
/// first chunk (titles carry strong topical signal).
public enum EmbeddingInput {
    public static let defaultMaxCharsPerChunk = 1000

    /// The combined title + body text, with the title on its own leading line.
    public static func combinedText(title: String, bodyText: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmedTitle.isEmpty, trimmedBody.isEmpty) {
        case (true, true): return ""
        case (false, true): return trimmedTitle
        case (true, false): return trimmedBody
        case (false, false): return trimmedTitle + "\n" + trimmedBody
        }
    }

    /// Splits the combined text into chunks of at most `maxCharsPerChunk` characters,
    /// preferring to break on whitespace so words/sentences stay intact. A document
    /// with no text returns `[]` (nothing to embed). A short document returns one
    /// chunk.
    public static func chunks(
        title: String,
        bodyText: String,
        maxCharsPerChunk: Int = defaultMaxCharsPerChunk
    ) -> [String] {
        precondition(maxCharsPerChunk > 0, "maxCharsPerChunk must be positive")
        let combined = combinedText(title: title, bodyText: bodyText)
        guard !combined.isEmpty else { return [] }
        if combined.count <= maxCharsPerChunk { return [combined] }

        var chunks: [String] = []
        var current = combined[...]
        while !current.isEmpty {
            if current.count <= maxCharsPerChunk {
                chunks.append(String(current))
                break
            }
            let hardEnd = current.index(current.startIndex, offsetBy: maxCharsPerChunk)
            // Prefer the last whitespace at/under the cap so we don't slice a word;
            // if there's none in this window, hard-split at the cap.
            let breakIndex = current[..<hardEnd].lastIndex(where: { $0.isWhitespace }) ?? hardEnd
            let cut = breakIndex == current.startIndex ? hardEnd : breakIndex
            let piece = current[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            current = current[cut...].drop(while: { $0.isWhitespace })
        }
        return chunks
    }
}
