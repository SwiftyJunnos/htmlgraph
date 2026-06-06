import Foundation
import SwiftSoup

public struct HTMLMetadataExtractor {
    public init() {}

    public func title(from html: String, fallbackFilename: String) throws -> String {
        let document = try SwiftSoup.parse(html)
        let title = try document.title().trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }

        let h1 = try document.select("h1").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !h1.isEmpty {
            return h1
        }

        return URL(fileURLWithPath: fallbackFilename).deletingPathExtension().lastPathComponent
    }

    /// Extracts the visible body text for embedding: tags stripped, `<script>`/
    /// `<style>` contents removed, whitespace collapsed. A missing or implicit/empty
    /// body yields `""`. The result is capped at `maxChars` characters (the head of
    /// the document, which carries the most topical signal).
    public func bodyText(from html: String, maxChars: Int = 4000) throws -> String {
        let document = try SwiftSoup.parse(html)
        guard let body = document.body() else { return "" }
        try body.select("script, style").remove()
        let text = try body.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars))
    }

    public func links(from html: String) throws -> [RawHTMLLink] {
        let document = try SwiftSoup.parse(html)
        return try document.select("a[href]").array().map { element in
            RawHTMLLink(
                href: try element.attr("href"),
                text: try element.text()
            )
        }
    }
}
