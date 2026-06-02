import XCTest
@testable import HTMLGraphCore

final class InboxAccepterTests: XCTestCase {
    func testAcceptMovesInboxItemToChosenVaultPath() throws {
        let vaultURL = try makeTemporaryVault(files: [
            "Inbox/idea.html": "<html><head><title>AI Idea</title></head><body></body></html>"
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let item = try XCTUnwrap(try InboxScanner().scanInbox(at: vaultURL).first)
        let destinationURL = vaultURL.appendingPathComponent("Notes/idea.html")

        let acceptedURL = try InboxAccepter().accept(item, to: destinationURL, vaultURL: vaultURL)

        XCTAssertEqual(acceptedURL.standardizedFileURL.path, destinationURL.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.absolutePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(try InboxScanner().scanInbox(at: vaultURL), [])
    }

    func testAcceptRejectsDestinationOutsideVault() throws {
        let vaultURL = try makeTemporaryVault(files: [
            "Inbox/idea.html": "<html><head><title>AI Idea</title></head><body></body></html>"
        ])
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLGraphInboxOutside-\(UUID().uuidString).html")
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }

        let item = try XCTUnwrap(try InboxScanner().scanInbox(at: vaultURL).first)

        XCTAssertThrowsError(try InboxAccepter().accept(item, to: outsideURL, vaultURL: vaultURL)) { error in
            XCTAssertEqual(error as? InboxAcceptanceError, .destinationOutsideVault)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.absolutePath))
    }

    func testAcceptRejectsInboxDestinationAndExistingFile() throws {
        let vaultURL = try makeTemporaryVault(files: [
            "Inbox/idea.html": "<html><head><title>AI Idea</title></head><body></body></html>",
            "Notes/existing.html": "<html><head><title>Existing</title></head><body></body></html>"
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let item = try XCTUnwrap(try InboxScanner().scanInbox(at: vaultURL).first)

        XCTAssertThrowsError(try InboxAccepter().accept(
            item,
            to: vaultURL.appendingPathComponent("Inbox/accepted.html"),
            vaultURL: vaultURL
        )) { error in
            XCTAssertEqual(error as? InboxAcceptanceError, .destinationInsideInbox)
        }

        XCTAssertThrowsError(try InboxAccepter().accept(
            item,
            to: vaultURL.appendingPathComponent("Notes/existing.html"),
            vaultURL: vaultURL
        )) { error in
            XCTAssertEqual(error as? InboxAcceptanceError, .destinationAlreadyExists)
        }
    }

    private func makeTemporaryVault(files: [String: String]) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLGraphInboxAcceptTests-\(UUID().uuidString)", isDirectory: true)

        for (path, contents) in files {
            let fileURL = rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return rootURL
    }
}
