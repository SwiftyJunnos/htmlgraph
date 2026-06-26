@testable import HTMLGraph
import HTMLGraphCore
import XCTest

final class DocumentPDFExporterTests: XCTestCase {
    func testDefaultFilenameReplacesHTMLPathExtensionWithPDF() {
        let document = makeDocument(path: "notes/release.notes.html")

        XCTAssertEqual(DocumentPDFExporter.defaultFilename(for: document), "release.notes.pdf")
    }

    func testDefaultFilenameAppendsPDFWhenDocumentHasNoExtension() {
        let document = makeDocument(path: "README")

        XCTAssertEqual(DocumentPDFExporter.defaultFilename(for: document), "README.pdf")
    }

    private func makeDocument(path: String) -> DocumentNode {
        DocumentNode(
            id: path,
            path: path,
            absolutePath: "/vault/\(path)",
            title: "Title",
            contentHash: "hash",
            lastModified: .distantPast
        )
    }
}
