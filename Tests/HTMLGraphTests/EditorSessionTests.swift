@testable import HTMLGraph
import HTMLGraphCore
import XCTest

/// Phase 2 of the in-app editor: the edit buffer's dirty tracking, the save round-trip
/// (disk write + incremental reindex + baseline reset), preview-identity invalidation,
/// and external-change conflict detection/resolution.
@MainActor
final class EditorSessionTests: XCTestCase {

    // MARK: - EditorBuffer (pure value semantics)

    func testEditorBufferIsCleanUntilTextDiverges() {
        var buffer = EditorBuffer(
            documentId: "index.html",
            baselineText: "<html></html>",
            currentText: "<html></html>",
            baselineHash: VaultIndexer.contentHash(forHTML: "<html></html>"),
            baselineMTime: .distantPast
        )
        XCTAssertFalse(buffer.isDirty)

        buffer.currentText = "<html><body>edit</body></html>"
        XCTAssertTrue(buffer.isDirty)

        // Typing back to the exact baseline is clean again — dirty is content equality,
        // not an edited-once flag.
        buffer.currentText = "<html></html>"
        XCTAssertFalse(buffer.isDirty)
    }

    // MARK: - beginEditing

    func testBeginEditingLoadsLiveDiskSourceIntoBuffer() throws {
        let source = "<html><head><title>Home</title></head><body>hi</body></html>"
        let (appState, _) = try openedVault(files: ["index.html": source])

        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        XCTAssertTrue(appState.beginEditing(document))

        let buffer = try XCTUnwrap(appState.editorBuffer)
        XCTAssertEqual(buffer.documentId, "index.html")
        XCTAssertEqual(buffer.baselineText, source)
        XCTAssertEqual(buffer.currentText, source)
        XCTAssertEqual(buffer.baselineHash, VaultIndexer.contentHash(forHTML: source))
        XCTAssertFalse(appState.hasUnsavedEdits)
    }

    func testBeginEditingRejectsPathEscapeOutsideVault() throws {
        let (appState, _) = try openedVault(files: [
            "index.html": "<html><head><title>Home</title></head><body></body></html>"
        ])
        let escaping = DocumentNode(
            id: "../escape.html",
            path: "../escape.html",
            absolutePath: "/tmp/escape.html",
            title: "Escape",
            contentHash: "x",
            lastModified: .distantPast
        )

        XCTAssertFalse(appState.beginEditing(escaping))
        XCTAssertNil(appState.editorBuffer)
        XCTAssertNotNil(appState.errorMessage)
    }

    // MARK: - Save round-trip

    func testSaveWritesToDiskPatchesIndexAndResetsBaseline() throws {
        let (appState, vaultURL) = try openedVault(files: [
            "index.html": "<html><head><title>Home</title></head><body></body></html>"
        ])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        XCTAssertTrue(appState.beginEditing(document))

        let edited = "<html><head><title>Renamed</title></head><body><p>new</p></body></html>"
        appState.updateEditorText(edited)
        XCTAssertTrue(appState.hasUnsavedEdits)

        XCTAssertTrue(appState.saveEditorBuffer())

        // Disk reflects the edit.
        let onDisk = try String(contentsOf: vaultURL.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertEqual(onDisk, edited)

        // The index was patched in place (no nil/full-reindex churn) and picked up the new title.
        XCTAssertEqual(appState.index?.document(id: "index.html")?.title, "Renamed")

        // Baseline reset to the saved text — buffer is clean and still pointed at the doc.
        let buffer = try XCTUnwrap(appState.editorBuffer)
        XCTAssertEqual(buffer.baselineText, edited)
        XCTAssertFalse(appState.hasUnsavedEdits)
        XCTAssertNil(appState.editorConflict)
    }

    func testSavedEditChangesContentHashAndWebViewIdentity() throws {
        let (appState, _) = try openedVault(files: [
            "index.html": "<html><head><title>Home</title></head><body></body></html>"
        ])
        let before = try XCTUnwrap(appState.index?.document(id: "index.html"))
        let identityBefore = WebViewIdentity.make(
            vaultPath: "/v", contentId: before.id, contentHash: before.contentHash,
            trustMode: .safe, allowsNetworkAccess: false
        )

        XCTAssertTrue(appState.beginEditing(before))
        appState.updateEditorText("<html><head><title>Home</title></head><body><p>changed</p></body></html>")
        XCTAssertTrue(appState.saveEditorBuffer())

        let after = try XCTUnwrap(appState.index?.document(id: "index.html"))
        XCTAssertNotEqual(after.contentHash, before.contentHash)

        let identityAfter = WebViewIdentity.make(
            vaultPath: "/v", contentId: after.id, contentHash: after.contentHash,
            trustMode: .safe, allowsNetworkAccess: false
        )
        // The preview's WKWebView is keyed on this string; a different hash forces a rebuild
        // so the rendered page reflects the saved source.
        XCTAssertNotEqual(identityAfter, identityBefore)
    }

    func testDiscardResetsCurrentTextToBaseline() throws {
        let source = "<html><head><title>Home</title></head><body></body></html>"
        let (appState, _) = try openedVault(files: ["index.html": source])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        XCTAssertTrue(appState.beginEditing(document))

        appState.updateEditorText("<html>scratch</html>")
        XCTAssertTrue(appState.hasUnsavedEdits)

        appState.discardEditorChanges()
        XCTAssertFalse(appState.hasUnsavedEdits)
        XCTAssertEqual(appState.editorBuffer?.currentText, source)
    }

    // MARK: - Conflict detection & resolution

    func testExternalChangeRaisesConflictInsteadOfOverwriting() throws {
        let original = "<html><head><title>Home</title></head><body></body></html>"
        let (appState, vaultURL) = try openedVault(files: ["index.html": original])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        XCTAssertTrue(appState.beginEditing(document))

        appState.updateEditorText("<html><body>mine</body></html>")

        // Someone else (external editor / inbox tool) rewrites the file under us.
        let theirs = "<html><body>theirs</body></html>"
        try theirs.write(to: vaultURL.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        XCTAssertFalse(appState.saveEditorBuffer())

        let conflict = try XCTUnwrap(appState.editorConflict)
        XCTAssertEqual(conflict.documentId, "index.html")
        XCTAssertEqual(conflict.pendingText, "<html><body>mine</body></html>")
        XCTAssertEqual(conflict.diskText, theirs)

        // The save did NOT clobber the external change.
        let onDisk = try String(contentsOf: vaultURL.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertEqual(onDisk, theirs)
    }

    func testResolveConflictByOverwritingWritesPendingText() throws {
        let (appState, vaultURL) = try openedVault(files: [
            "index.html": "<html><head><title>Home</title></head><body></body></html>"
        ])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        XCTAssertTrue(appState.beginEditing(document))
        appState.updateEditorText("<html><body>mine</body></html>")
        try "<html><body>theirs</body></html>".write(
            to: vaultURL.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
        XCTAssertFalse(appState.saveEditorBuffer())
        XCTAssertNotNil(appState.editorConflict)

        appState.resolveConflictByOverwriting()

        let onDisk = try String(contentsOf: vaultURL.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertEqual(onDisk, "<html><body>mine</body></html>")
        XCTAssertNil(appState.editorConflict)
        XCTAssertFalse(appState.hasUnsavedEdits)
    }

    func testResolveConflictByReloadingAdoptsDiskText() throws {
        let (appState, vaultURL) = try openedVault(files: [
            "index.html": "<html><head><title>Home</title></head><body></body></html>"
        ])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        XCTAssertTrue(appState.beginEditing(document))
        appState.updateEditorText("<html><body>mine</body></html>")
        let theirs = "<html><body>theirs</body></html>"
        try theirs.write(to: vaultURL.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        XCTAssertFalse(appState.saveEditorBuffer())
        XCTAssertNotNil(appState.editorConflict)

        appState.resolveConflictByReloading()

        let buffer = try XCTUnwrap(appState.editorBuffer)
        XCTAssertEqual(buffer.baselineText, theirs)
        XCTAssertEqual(buffer.currentText, theirs)
        XCTAssertFalse(appState.hasUnsavedEdits)
        XCTAssertNil(appState.editorConflict)
        // Disk is untouched by a reload.
        let onDisk = try String(contentsOf: vaultURL.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertEqual(onDisk, theirs)
    }

    // MARK: - Helpers

    /// Builds a temp vault, opens it in a fresh AppState, and indexes it synchronously so
    /// tests can drive the editor without awaiting the async open path.
    private func openedVault(files: [String: String]) throws -> (AppState, URL) {
        let vaultURL = try makeTemporaryVault(files: files)
        addTeardownBlock { try? FileManager.default.removeItem(at: vaultURL) }
        let appState = AppState()
        appState.vaultURL = vaultURL
        appState.index = try VaultIndexer().indexVault(at: vaultURL)
        return (appState, vaultURL)
    }

    private func makeTemporaryVault(files: [String: String]) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLGraphEditorTests-\(UUID().uuidString)", isDirectory: true)
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
