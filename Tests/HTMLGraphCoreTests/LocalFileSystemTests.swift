import XCTest
@testable import HTMLGraphCore

final class LocalFileSystemTests: XCTestCase {
    // MARK: - Enumeration

    func testEnumerateFilesReturnsRelativePathsRecursivelySkippingHidden() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("<h1>a</h1>", to: root, relative: "a.html")
        try write("<h1>b</h1>", to: root, relative: "sub/b.html")
        try write("secret", to: root, relative: ".hidden.html")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty", isDirectory: true), withIntermediateDirectories: true)

        let fs = LocalFileSystem(root: root)
        let entries = try await fs.enumerateFiles(under: "")
        let paths = entries.map(\.relativePath).sorted()

        XCTAssertEqual(paths, ["a.html", "sub/b.html"])
    }

    func testEnumerateFilesCarriesSizeAndModificationDate() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = "0123456789"
        try write(body, to: root, relative: "a.html")

        let fs = LocalFileSystem(root: root)
        let entries = try await fs.enumerateFiles(under: "")
        let entry = try XCTUnwrap(entries.first)

        XCTAssertEqual(entry.relativePath, "a.html")
        XCTAssertEqual(entry.size, body.utf8.count)
        XCTAssertGreaterThan(entry.modificationDate.timeIntervalSince1970, 0)
    }

    func testEnumerateUnderSubpathScopesToThatDirectory() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("<h1>root</h1>", to: root, relative: "root.html")
        try write("<h1>in</h1>", to: root, relative: "Inbox/item.html")

        let fs = LocalFileSystem(root: root)
        let paths = try await fs.enumerateFiles(under: "Inbox").map(\.relativePath).sorted()

        XCTAssertEqual(paths, ["Inbox/item.html"])
    }

    func testEnumerateMissingDirectoryYieldsEmpty() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)

        let entries = try await fs.enumerateFiles(under: "does-not-exist")
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Containment

    func testPathEscapeThrowsOutsideVault() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)

        await assertThrows(.outsideVault("../escape.html")) {
            _ = try await fs.readData(at: "../escape.html")
        }
        await assertThrows(.outsideVault("sub/../../escape.html")) {
            try await fs.writeText("x", to: "sub/../../escape.html", options: [.atomic])
        }
    }

    // MARK: - Read / write round-trips

    func testWriteThenReadTextRoundTrips() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)

        try await fs.writeText("<h1>héllo</h1>", to: "note.html", options: [.atomic])
        let text = try await fs.readText(at: "note.html")
        XCTAssertEqual(text, "<h1>héllo</h1>")
    }

    func testReadDataRoundTrips() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)

        let bytes = Data((0..<256).map { UInt8($0) })
        try await fs.writeData(bytes, to: "blob.bin", options: [.atomic])
        let read = try await fs.readData(at: "blob.bin")
        XCTAssertEqual(read, bytes)
    }

    func testReadMissingFileThrowsNotFound() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)

        await assertThrows(.notFound("ghost.html")) {
            _ = try await fs.readData(at: "ghost.html")
        }
        await assertThrows(.notFound("ghost.html")) {
            _ = try await fs.readText(at: "ghost.html")
        }
    }

    func testReadRangeReturnsRequestedSlice() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)
        try await fs.writeText("0123456789", to: "f.txt", options: [.atomic])

        let slice = try await fs.readRange(at: "f.txt", 2..<5)
        XCTAssertEqual(String(data: slice, encoding: .utf8), "234")
    }

    func testWithoutOverwritingThrowsAlreadyExistsOnSecondWrite() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)

        try await fs.writeData(Data("first".utf8), to: "once.md", options: [.withoutOverwriting])
        await assertThrows(.alreadyExists("once.md")) {
            try await fs.writeData(Data("second".utf8), to: "once.md", options: [.withoutOverwriting])
        }
        // The original content survives the rejected write.
        let text = try await fs.readText(at: "once.md")
        XCTAssertEqual(text, "first")
    }

    // MARK: - Mutations

    func testCreateDirectoryCreatesIntermediates() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)

        try await fs.createDirectory(at: "a/b/c")
        try await fs.writeText("<h1>deep</h1>", to: "a/b/c/note.html", options: [.atomic])
        let deep = try await fs.readText(at: "a/b/c/note.html")
        XCTAssertEqual(deep, "<h1>deep</h1>")
    }

    func testMoveRelocatesFile() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)
        try await fs.writeText("<h1>x</h1>", to: "from.html", options: [.atomic])
        try await fs.createDirectory(at: "dest")

        try await fs.move(from: "from.html", to: "dest/to.html")
        let movedExists = await fs.exists(at: "dest/to.html")
        let sourceExists = await fs.exists(at: "from.html")
        XCTAssertTrue(movedExists)
        XCTAssertFalse(sourceExists)
    }

    func testCopyDuplicatesFile() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)
        try await fs.writeText("<h1>x</h1>", to: "orig.html", options: [.atomic])

        try await fs.copy(from: "orig.html", to: "copy.html")
        let origExists = await fs.exists(at: "orig.html")
        XCTAssertTrue(origExists)
        let copyText = try await fs.readText(at: "copy.html")
        XCTAssertEqual(copyText, "<h1>x</h1>")
    }

    func testRemoveDeletesFile() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)
        try await fs.writeText("x", to: "doomed.html", options: [.atomic])

        try await fs.remove(at: "doomed.html")
        let exists = await fs.exists(at: "doomed.html")
        XCTAssertFalse(exists)
    }

    func testTrashRemovesFromVault() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)
        try await fs.writeText("x", to: "trashme.html", options: [.atomic])

        try await fs.trash(at: "trashme.html")
        let exists = await fs.exists(at: "trashme.html")
        XCTAssertFalse(exists)
    }

    func testContentsOfDirectoryListsImmediateChildren() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)
        try await fs.createDirectory(at: "dir")
        try await fs.writeText("a", to: "dir/a.html", options: [.atomic])
        try await fs.writeText("b", to: "dir/b.html", options: [.atomic])

        let names = try await fs.contentsOfDirectory(at: "dir").sorted()
        XCTAssertEqual(names, ["a.html", "b.html"])
    }

    // MARK: - Metadata

    func testMetadataDistinguishesFileAndDirectory() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)
        try await fs.createDirectory(at: "dir")
        try await fs.writeText("hello", to: "dir/file.html", options: [.atomic])

        let fileMeta = try await fs.metadata(at: "dir/file.html")
        XCTAssertTrue(fileMeta.isRegularFile)
        XCTAssertFalse(fileMeta.isDirectory)
        XCTAssertEqual(fileMeta.size, "hello".utf8.count)

        let dirMeta = try await fs.metadata(at: "dir")
        XCTAssertTrue(dirMeta.isDirectory)
        XCTAssertFalse(dirMeta.isRegularFile)
    }

    func testMetadataMissingThrowsNotFound() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)

        await assertThrows(.notFound("nope")) {
            _ = try await fs.metadata(at: "nope")
        }
    }

    func testExistsReflectsPresence() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)

        var present = await fs.exists(at: "x.html")
        XCTAssertFalse(present)
        try await fs.writeText("x", to: "x.html", options: [.atomic])
        present = await fs.exists(at: "x.html")
        XCTAssertTrue(present)
    }

    func testAbsolutePathResolvesUnderRoot() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem(root: root)

        let path = fs.absolutePath(for: "notes/x.html")
        XCTAssertEqual(path, root.appendingPathComponent("notes/x.html").path)
        XCTAssertNil(fs.absolutePath(for: "../escape"))
    }

    // MARK: - Helpers

    /// Runs `body`, failing if it does not throw the expected `VaultFileSystemError`.
    private func assertThrows(
        _ expected: VaultFileSystemError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected) but no error was thrown", file: file, line: line)
        } catch let error as VaultFileSystemError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected) but got \(error)", file: file, line: line)
        }
    }

    private func write(_ contents: String, to root: URL, relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFileSystemTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
