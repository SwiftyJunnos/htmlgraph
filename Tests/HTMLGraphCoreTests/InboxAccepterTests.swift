import XCTest
@testable import HTMLGraphCore

final class InboxAccepterTests: XCTestCase {
    func testAcceptMovesInboxItemToChosenVaultPath() async throws {
        let vaultURL = try makeTemporaryVault(files: [
            "Inbox/idea.html": "<html><head><title>AI Idea</title></head><body></body></html>"
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let scanned = try await InboxScanner().scanInbox(at: vaultURL)
        let item = try XCTUnwrap(scanned.first)

        let accepted = try await InboxAccepter().accept(
            item, toRelativePath: "Notes/idea.html", fileSystem: LocalFileSystem(root: vaultURL))

        XCTAssertEqual(accepted, "Notes/idea.html")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.absolutePath))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vaultURL.appendingPathComponent("Notes/idea.html").path))
        let remaining = try await InboxScanner().scanInbox(at: vaultURL)
        XCTAssertEqual(remaining, [])
    }

    func testAcceptRejectsDestinationOutsideVault() async throws {
        let vaultURL = try makeTemporaryVault(files: [
            "Inbox/idea.html": "<html><head><title>AI Idea</title></head><body></body></html>"
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let scanned = try await InboxScanner().scanInbox(at: vaultURL)
        let item = try XCTUnwrap(scanned.first)
        let fileSystem = LocalFileSystem(root: vaultURL)

        do {
            _ = try await InboxAccepter().accept(item, toRelativePath: "../outside.html", fileSystem: fileSystem)
            XCTFail("expected destinationOutsideVault")
        } catch let error as InboxAcceptanceError {
            XCTAssertEqual(error, .destinationOutsideVault)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.absolutePath))
    }

    func testAcceptRejectsInboxDestinationAndExistingFile() async throws {
        let vaultURL = try makeTemporaryVault(files: [
            "Inbox/idea.html": "<html><head><title>AI Idea</title></head><body></body></html>",
            "Notes/existing.html": "<html><head><title>Existing</title></head><body></body></html>"
        ])
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let scanned = try await InboxScanner().scanInbox(at: vaultURL)
        let item = try XCTUnwrap(scanned.first)
        let fileSystem = LocalFileSystem(root: vaultURL)

        do {
            _ = try await InboxAccepter().accept(item, toRelativePath: "Inbox/accepted.html", fileSystem: fileSystem)
            XCTFail("expected destinationInsideInbox")
        } catch let error as InboxAcceptanceError {
            XCTAssertEqual(error, .destinationInsideInbox)
        }

        do {
            _ = try await InboxAccepter().accept(item, toRelativePath: "Notes/existing.html", fileSystem: fileSystem)
            XCTFail("expected destinationAlreadyExists")
        } catch let error as InboxAcceptanceError {
            XCTAssertEqual(error, .destinationAlreadyExists)
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
