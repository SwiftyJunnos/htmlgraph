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
