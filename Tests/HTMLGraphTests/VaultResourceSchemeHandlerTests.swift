import Foundation
@testable import HTMLGraph
import HTMLGraphCore
import XCTest

final class VaultResourceSchemeHandlerTests: XCTestCase {
    private let vaultURL = URL(fileURLWithPath: "/tmp/vault", isDirectory: true)
    private let policy = VaultSecurityPolicy(mode: .safe, allowsNetworkAccess: false)

    func testMapsVaultSchemeURLToFileInsideVault() {
        let requestURL = URL(string: "htmlgraph://vault/notes/My%20Page.html")!

        let fileURL = VaultResourceSchemeHandler.fileURL(
            for: requestURL,
            vaultURL: vaultURL,
            policy: policy
        )

        XCTAssertEqual(fileURL?.path, "/tmp/vault/notes/My Page.html")
    }

    func testRejectsTraversalOutsideVault() {
        let requestURL = URL(string: "htmlgraph://vault/../secret.html")!

        XCTAssertNil(VaultResourceSchemeHandler.fileURL(for: requestURL, vaultURL: vaultURL, policy: policy))
    }

    func testRejectsWrongSchemeHostAndEncodedTraversal() {
        XCTAssertNil(
            VaultResourceSchemeHandler.fileURL(
                for: URL(string: "https://vault/index.html")!,
                vaultURL: vaultURL,
                policy: policy
            )
        )
        XCTAssertNil(
            VaultResourceSchemeHandler.fileURL(
                for: URL(string: "htmlgraph://other/index.html")!,
                vaultURL: vaultURL,
                policy: policy
            )
        )
        XCTAssertNil(
            VaultResourceSchemeHandler.fileURL(
                for: URL(string: "htmlgraph://vault/%2E%2E/secret.html")!,
                vaultURL: vaultURL,
                policy: policy
            )
        )
    }

    func testBuildsPercentEncodedVaultURLFromFileURL() {
        let fileURL = vaultURL.appendingPathComponent("notes/My Page.html")

        let requestURL = VaultResourceSchemeHandler.vaultURL(for: fileURL, vaultURL: vaultURL)

        XCTAssertEqual(requestURL?.absoluteString, "htmlgraph://vault/notes/My%20Page.html")
    }

    func testMimeTypesCoverKnownExtensionsAndFallback() {
        XCTAssertEqual(VaultResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "index.html")), "text/html")
        XCTAssertEqual(VaultResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "style.css")), "text/css")
        XCTAssertEqual(VaultResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "script.js")), "text/javascript")
        XCTAssertEqual(VaultResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "icon.svg")), "image/svg+xml")
        XCTAssertEqual(VaultResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "image.png")), "image/png")
        XCTAssertEqual(VaultResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "photo.jpeg")), "image/jpeg")
        XCTAssertEqual(VaultResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "file.bin")), "application/octet-stream")
    }
}
