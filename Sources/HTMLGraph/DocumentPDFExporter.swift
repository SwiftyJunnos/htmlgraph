import Foundation
import HTMLGraphCore
import WebKit

enum DocumentPDFExportError: LocalizedError {
    case rendererUnavailable
    case emptyPDFData

    var errorDescription: String? {
        switch self {
        case .rendererUnavailable:
            return "The document preview is not ready to export yet."
        case .emptyPDFData:
            return "The document preview did not produce a PDF."
        }
    }
}

enum DocumentPDFExporter {
    static func defaultFilename(for document: DocumentNode) -> String {
        let filename = (document.path as NSString).lastPathComponent
        let baseName = (filename as NSString).deletingPathExtension
        return "\(baseName.isEmpty ? "document" : baseName).pdf"
    }

    @MainActor
    static func pdfData(from webView: WKWebView) async throws -> Data {
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(origin: .zero, size: await pdfContentSize(for: webView))

        let data = try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: configuration) { result in
                continuation.resume(with: result)
            }
        }
        guard !data.isEmpty else { throw DocumentPDFExportError.emptyPDFData }
        return data
    }

    @MainActor
    private static func pdfContentSize(for webView: WKWebView) async -> CGSize {
        let visibleSize = webView.bounds.size
        let documentSize = await measuredDocumentSize(in: webView) ?? .zero
        return CGSize(
            width: max(visibleSize.width, documentSize.width, 1),
            height: max(visibleSize.height, documentSize.height, 1)
        )
    }

    @MainActor
    private static func measuredDocumentSize(in webView: WKWebView) async -> CGSize? {
        let script = """
        (() => {
          const body = document.body || {};
          const html = document.documentElement || {};
          const width = Math.max(
            body.scrollWidth || 0,
            body.offsetWidth || 0,
            html.clientWidth || 0,
            html.scrollWidth || 0,
            html.offsetWidth || 0
          );
          const height = Math.max(
            body.scrollHeight || 0,
            body.offsetHeight || 0,
            html.clientHeight || 0,
            html.scrollHeight || 0,
            html.offsetHeight || 0
          );
          return `${width},${height}`;
        })()
        """

        let measurement = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        guard let measurement else { return nil }
        let parts = measurement.split(separator: ",", maxSplits: 1).compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
}

@MainActor
final class PDFExportBridge {
    private struct Registration {
        let id: UUID
        let handler: () async throws -> Data
    }

    private var registration: Registration?

    func register(id: UUID, handler: @escaping () async throws -> Data) {
        registration = Registration(id: id, handler: handler)
    }

    func unregister(id: UUID) {
        guard registration?.id == id else { return }
        registration = nil
    }

    func export() async throws -> Data {
        guard let handler = registration?.handler else {
            throw DocumentPDFExportError.rendererUnavailable
        }
        return try await handler()
    }
}
