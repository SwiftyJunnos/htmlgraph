import AppKit
import HTMLGraphCore

/// The live editing state for one document's HTML source. Held by `AppState` (not by a
/// view) so the buffer survives transient view re-evaluations — a reindex flipping
/// `isIndexing`, the 2s inbox poll, or the preview web view rebuilding must never discard
/// unsaved text. It's a plain value type so mutating `currentText` republishes `AppState`.
struct EditorBuffer: Equatable {
    /// The vault-relative id of the document being edited. Used to re-derive the file
    /// path at save time (never trust a captured absolute path that a move could stale).
    let documentId: String
    /// The exact bytes loaded into the editor — the comparison point for "dirty" and for
    /// conflict detection.
    let baselineText: String
    var currentText: String
    /// Index-style hash (`VaultIndexer.contentHash`) of `baselineText`, compared against
    /// the on-disk hash right before a write to detect an external change.
    let baselineHash: String
    let baselineMTime: Date

    var isDirty: Bool { currentText != baselineText }
}

/// Raised when the file changed on disk (its hash no longer matches the editor's
/// baseline) between opening it and saving. Carries both sides so the resolution UI can
/// overwrite with the user's text or reload the disk version.
struct EditorConflict: Identifiable, Equatable {
    let id = UUID()
    let documentId: String
    /// The user's unsaved text, written if they choose "Overwrite".
    let pendingText: String
    /// The current on-disk text, loaded into the editor if they choose "Reload".
    let diskText: String
    let diskHash: String
    let diskMTime: Date
}

enum UnsavedEditsChoice {
    case save
    case discard
    case cancel
}

/// Coordinates the "you have unsaved edits" prompt for any navigation or mutation that
/// would tear down or leave the editor. Lives in the UI layer (it runs an `NSAlert`,
/// mirroring `SidebarCommands`) so `AppState` stays a testable, alert-free model.
@MainActor
enum EditorGuard {
    /// Returns true when it is safe to proceed (nothing dirty, the user saved, or the
    /// user discarded). Returns false to abort the caller's action (the user cancelled,
    /// or the save surfaced a conflict that must be resolved first).
    static func confirmLeavingEditor(_ appState: AppState) -> Bool {
        guard appState.hasUnsavedEdits, let buffer = appState.editorBuffer else { return true }
        let title = appState.index?.document(id: buffer.documentId)?.title ?? buffer.documentId
        switch promptUnsavedEdits(documentTitle: title) {
        case .save:
            // A clean save clears the dirty flag; a conflict blocks the navigation until
            // the user resolves it via the conflict alert.
            return appState.saveEditorBuffer()
        case .discard:
            appState.endEditing()
            return true
        case .cancel:
            return false
        }
    }

    /// Three-way Save / Discard / Cancel prompt, matching macOS document conventions.
    static func promptUnsavedEdits(documentTitle: String) -> UnsavedEditsChoice {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(documentTitle)” before closing?"
        alert.informativeText = "If you don’t save, your changes will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}
