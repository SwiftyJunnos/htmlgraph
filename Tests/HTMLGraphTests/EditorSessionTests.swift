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

    func testBeginEditingLoadsLiveDiskSourceIntoBuffer() async throws {
        let source = "<html><head><title>Home</title></head><body>hi</body></html>"
        let (appState, _) = try await openedVault(files: ["index.html": source])

        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        let didBegin = await appState.beginEditing(document)
        XCTAssertTrue(didBegin)

        let buffer = try XCTUnwrap(appState.editorBuffer)
        XCTAssertEqual(buffer.documentId, "index.html")
        XCTAssertEqual(buffer.baselineText, source)
        XCTAssertEqual(buffer.currentText, source)
        XCTAssertEqual(buffer.baselineHash, VaultIndexer.contentHash(forHTML: source))
        XCTAssertFalse(appState.hasUnsavedEdits)
    }

    func testBeginEditingRejectsPathEscapeOutsideVault() async throws {
        let (appState, _) = try await openedVault(files: [
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

        let didBegin = await appState.beginEditing(escaping)
        XCTAssertFalse(didBegin)
        XCTAssertNil(appState.editorBuffer)
        XCTAssertNotNil(appState.errorMessage)
    }

    // MARK: - Save round-trip

    func testSaveWritesToDiskPatchesIndexAndResetsBaseline() async throws {
        let (appState, vaultURL) = try await openedVault(files: [
            "index.html": "<html><head><title>Home</title></head><body></body></html>"
        ])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        let didBegin = await appState.beginEditing(document)
        XCTAssertTrue(didBegin)

        let edited = "<html><head><title>Renamed</title></head><body><p>new</p></body></html>"
        appState.updateEditorText(edited)
        XCTAssertTrue(appState.hasUnsavedEdits)

        let didSave = await appState.saveEditorBuffer()
        XCTAssertTrue(didSave)

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

    func testSavedEditChangesContentHashAndWebViewIdentity() async throws {
        let (appState, _) = try await openedVault(files: [
            "index.html": "<html><head><title>Home</title></head><body></body></html>"
        ])
        let before = try XCTUnwrap(appState.index?.document(id: "index.html"))
        let identityBefore = WebViewIdentity.make(
            vaultPath: "/v", contentId: before.id, contentHash: before.contentHash,
            trustMode: .safe, allowsNetworkAccess: false
        )

        let didBegin = await appState.beginEditing(before)
        XCTAssertTrue(didBegin)
        appState.updateEditorText("<html><head><title>Home</title></head><body><p>changed</p></body></html>")
        let didSave = await appState.saveEditorBuffer()
        XCTAssertTrue(didSave)

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

    func testDiscardResetsCurrentTextToBaseline() async throws {
        let source = "<html><head><title>Home</title></head><body></body></html>"
        let (appState, _) = try await openedVault(files: ["index.html": source])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        let didBegin = await appState.beginEditing(document)
        XCTAssertTrue(didBegin)

        appState.updateEditorText("<html>scratch</html>")
        XCTAssertTrue(appState.hasUnsavedEdits)

        appState.discardEditorChanges()
        XCTAssertFalse(appState.hasUnsavedEdits)
        XCTAssertEqual(appState.editorBuffer?.currentText, source)
    }

    // MARK: - Visual (WYSIWYG) editing bridge

    /// The visual editor posts its *first* snapshot (the unedited DOM) on load; the host
    /// adopts it as the clean reference. Subsequent snapshots are real edits.
    private func sendVisualBaseline(_ appState: AppState, documentId: String, body: String) {
        appState.updateVisualEditedDocument(documentId: documentId, bodyInnerHTML: body, fullHTML: nil)
    }

    func testVisualBodyEditSplicesIntoSourceAndSavesPreservingHead() async throws {
        let source = "<!DOCTYPE html><html><head><title>Home</title></head><body><p>old</p></body></html>"
        let (appState, vaultURL) = try await openedVault(files: ["index.html": source])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        let didBegin = await appState.beginEditing(document)
        XCTAssertTrue(didBegin)
        appState.beginVisualSession()
        XCTAssertFalse(appState.hasUnsavedEdits)

        // Initial (unedited) snapshot establishes the clean reference; not an edit.
        sendVisualBaseline(appState, documentId: "index.html", body: "<p>old</p>")
        XCTAssertFalse(appState.hasUnsavedEdits)

        // Then a real edit as the user types.
        appState.updateVisualEditedDocument(documentId: "index.html", bodyInnerHTML: "<p>edited</p>", fullHTML: nil)

        // Only the body inner span changed; the doctype/head are spliced back untouched.
        let expected = "<!DOCTYPE html><html><head><title>Home</title></head><body><p>edited</p></body></html>"
        XCTAssertEqual(appState.editorBuffer?.currentText, expected)
        XCTAssertTrue(appState.hasUnsavedEdits)

        let didSave = await appState.saveEditorBuffer()
        XCTAssertTrue(didSave)
        let onDisk = try String(contentsOf: vaultURL.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertEqual(onDisk, expected)
        // Title (from <head>, which we never touched) is intact; baseline reset to the save.
        XCTAssertEqual(appState.index?.document(id: "index.html")?.title, "Home")
        XCTAssertFalse(appState.hasUnsavedEdits)
    }

    func testVisualReserializationAloneIsNotAnEdit() async throws {
        // Body inner uses non-canonical formatting on disk; the editor's first snapshot is
        // WebKit's normalized re-serialization. That difference must NOT read as an edit —
        // otherwise clicking Done with no real change would wrongly prompt Save/Discard.
        let source = "<html><head><title>T</title></head><body><p >x</p></body></html>"
        let (appState, _) = try await openedVault(files: ["index.html": source])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        let didBegin = await appState.beginEditing(document)
        XCTAssertTrue(didBegin)
        appState.beginVisualSession()

        sendVisualBaseline(appState, documentId: "index.html", body: "<p>x</p>")  // normalized form
        XCTAssertFalse(appState.hasUnsavedEdits)  // re-serialization alone is not dirty

        // A genuine content change after that IS dirty.
        appState.updateVisualEditedDocument(documentId: "index.html", bodyInnerHTML: "<p>y</p>", fullHTML: nil)
        XCTAssertTrue(appState.hasUnsavedEdits)
    }

    func testVisualEditFallsBackToFullSerializationWhenBodyNotLocatable() async throws {
        // A valid full document with an IMPLIED body (no literal <body> tag): the splice can't
        // locate a body region, so it must NOT write the bare fragment (which would destroy
        // the head/doctype). It uses the DOM's full serialization instead — no data loss.
        let source = "<!DOCTYPE html><html><head><title>T</title></head><p>x</p></html>"
        let (appState, vaultURL) = try await openedVault(files: ["index.html": source])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        let didBegin = await appState.beginEditing(document)
        XCTAssertTrue(didBegin)
        appState.beginVisualSession()

        // Initial snapshot: splice can't locate a body, so the clean reference is the full
        // serialization (passed as fullHTML).
        let baseline = "<!DOCTYPE html><html><head><title>T</title></head><body><p>x</p></body></html>"
        appState.updateVisualEditedDocument(documentId: "index.html", bodyInnerHTML: "<p>x</p>", fullHTML: baseline)
        XCTAssertFalse(appState.hasUnsavedEdits)

        let full = "<!DOCTYPE html><html><head><title>T</title></head><body><p>edited</p></body></html>"
        appState.updateVisualEditedDocument(documentId: "index.html", bodyInnerHTML: "<p>edited</p>", fullHTML: full)
        XCTAssertEqual(appState.editorBuffer?.currentText, full)
        XCTAssertTrue(appState.hasUnsavedEdits)

        let didSave = await appState.saveEditorBuffer()
        XCTAssertTrue(didSave)
        let onDisk = try String(contentsOf: vaultURL.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertEqual(onDisk, full)  // head/title/doctype preserved (via the DOM), not dropped
    }

    func testVisualEditIgnoresSnapshotForADifferentDocument() async throws {
        // A late snapshot posted by an outgoing editor (different documentId) must not corrupt
        // the buffer that has since been re-baselined to another document.
        let source = "<html><head><title>Home</title></head><body><p>a</p></body></html>"
        let (appState, _) = try await openedVault(files: ["index.html": source])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        let didBegin = await appState.beginEditing(document)
        XCTAssertTrue(didBegin)
        appState.beginVisualSession()

        appState.updateVisualEditedDocument(documentId: "stale-other.html", bodyInnerHTML: "<p>WRONG</p>", fullHTML: nil)
        XCTAssertFalse(appState.hasUnsavedEdits)
        XCTAssertEqual(appState.editorBuffer?.currentText, source)
    }

    func testVisualSnapshotIgnoredAfterLeavingVisualSession() async throws {
        // Switching visual -> source re-baselines the buffer; a late snapshot from the
        // outgoing visual editor (same documentId) must NOT overwrite the source buffer with
        // re-serialized HTML.
        let source = "<html><head><title>Home</title></head><body><p>a</p></body></html>"
        let (appState, _) = try await openedVault(files: ["index.html": source])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        let didBeginVisual = await appState.beginEditing(document)
        XCTAssertTrue(didBeginVisual)
        appState.beginVisualSession()

        // Simulate leaving the visual surface (e.g. switching to source) — endEditing then a
        // fresh begin, without a new visual session.
        appState.endEditing()
        let didReBegin = await appState.beginEditing(document)
        XCTAssertTrue(didReBegin)

        // A stale snapshot from the dismantling visual editor is dropped, not applied.
        appState.updateVisualEditedDocument(documentId: "index.html", bodyInnerHTML: "<p>STALE</p>", fullHTML: nil)
        XCTAssertFalse(appState.hasUnsavedEdits)
        XCTAssertEqual(appState.editorBuffer?.currentText, source)
    }

    // MARK: - Conflict detection & resolution

    func testExternalChangeRaisesConflictInsteadOfOverwriting() async throws {
        let original = "<html><head><title>Home</title></head><body></body></html>"
        let (appState, vaultURL) = try await openedVault(files: ["index.html": original])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        let didBegin = await appState.beginEditing(document)
        XCTAssertTrue(didBegin)

        appState.updateEditorText("<html><body>mine</body></html>")

        // Someone else (external editor / inbox tool) rewrites the file under us.
        let theirs = "<html><body>theirs</body></html>"
        try theirs.write(to: vaultURL.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let didSave = await appState.saveEditorBuffer()
        XCTAssertFalse(didSave)

        let conflict = try XCTUnwrap(appState.editorConflict)
        XCTAssertEqual(conflict.documentId, "index.html")
        XCTAssertEqual(conflict.pendingText, "<html><body>mine</body></html>")
        XCTAssertEqual(conflict.diskText, theirs)

        // The save did NOT clobber the external change.
        let onDisk = try String(contentsOf: vaultURL.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertEqual(onDisk, theirs)
    }

    func testResolveConflictByOverwritingWritesPendingText() async throws {
        let (appState, vaultURL) = try await openedVault(files: [
            "index.html": "<html><head><title>Home</title></head><body></body></html>"
        ])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        let didBegin = await appState.beginEditing(document)
        XCTAssertTrue(didBegin)
        appState.updateEditorText("<html><body>mine</body></html>")
        try "<html><body>theirs</body></html>".write(
            to: vaultURL.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
        let didSave = await appState.saveEditorBuffer()
        XCTAssertFalse(didSave)
        XCTAssertNotNil(appState.editorConflict)

        await appState.resolveConflictByOverwriting()

        let onDisk = try String(contentsOf: vaultURL.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertEqual(onDisk, "<html><body>mine</body></html>")
        XCTAssertNil(appState.editorConflict)
        XCTAssertFalse(appState.hasUnsavedEdits)
    }

    func testResolveConflictByReloadingAdoptsDiskText() async throws {
        let (appState, vaultURL) = try await openedVault(files: [
            "index.html": "<html><head><title>Home</title></head><body></body></html>"
        ])
        let document = try XCTUnwrap(appState.index?.document(id: "index.html"))
        let didBegin = await appState.beginEditing(document)
        XCTAssertTrue(didBegin)
        appState.updateEditorText("<html><body>mine</body></html>")
        let theirs = "<html><body>theirs</body></html>"
        try theirs.write(to: vaultURL.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let didSave = await appState.saveEditorBuffer()
        XCTAssertFalse(didSave)
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
    private func openedVault(files: [String: String]) async throws -> (AppState, URL) {
        let vaultURL = try makeTemporaryVault(files: files)
        addTeardownBlock { try? FileManager.default.removeItem(at: vaultURL) }
        let appState = AppState()
        appState.vaultURL = vaultURL
        appState.index = try await VaultIndexer().indexVault(at: vaultURL)
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
