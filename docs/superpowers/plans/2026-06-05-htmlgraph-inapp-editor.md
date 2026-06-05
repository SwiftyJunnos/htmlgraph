# HTMLGraph In-App Editor — Implementation Plan

_Date: 2026-06-05_

## Problem

HTMLGraph can read a vault and mutate its files (create / rename / move / trash /
duplicate / new folder), but it **cannot edit a document's content in-app**. The only
edit path today is `ExternalEditor` ("Open in Editor") in `ReaderPane.swift`, which
hands the file to VS Code / Cursor / etc. — a context switch out of the app. This plan
adds an **in-app HTML editor** so a user can change a document's content and immediately
see the graph / preview / backlinks reflect the edit.

## Approach decision

Three approaches were designed and adversarially critiqued:

| Approach | Effort | Verdict | Reason |
|---|---|---|---|
| **A. HTML source editor + incremental reindex** | L | **Adopt** (with changes) | Faithful bytes, stays in Safe mode, no view destruction |
| B. WYSIWYG (`contentEditable`) | XL | Reject | Irreversibly mangles arbitrary/AI-generated HTML on first save; requires JS → couples to Trusted mode |
| C. Minimal MVP (full reindex per save) | M | Reject | A full reindex tears the editor subtree down mid-edit |

**Spine = Approach A**, grafting Approach C's "smallest shippable surface" discipline.
The codebase forces this:

1. **Fidelity** — documents are arbitrary / AI-generated HTML served byte-for-byte by
   `VaultHTTPServer`. A WYSIWYG round-trip (`contentEditable` → `outerHTML`) drops
   comments, `<!DOCTYPE>`, `<pre>` whitespace, and entities on the very first save.
   Source editing writes the user's exact bytes via
   `write(to:atomically:true,encoding:.utf8)`.
2. **Safe-mode / JS coupling** — editing source in a plain-text `NSTextView` needs **no
   JavaScript and no Trusted mode**. No `WKWebView` is instantiated for editing, so the
   `allowsContentJavaScript` gate and the `WKContentRuleList` network gate are entirely
   bypassed while editing; policy re-applies only when the preview rebuilds in
   `makeNSView`. **Zero new trust surface.**
3. **Full reindex destroys the view** — `beginSession` synchronously sets `index = nil`
   / `sidebarSelection = nil` / `isIndexing = true` (`AppState.swift:457-460`), and the
   first branch of `ReaderPane.body`, `if appState.isIndexing` (`ReaderPane.swift:40`),
   replaces the whole editor subtree with a `ProgressView`. So an **incremental
   single-document reindex is the load-bearing part** and gets its own phase.
4. **Sandbox** — writes reuse the `accessedVaultURL` security-scoped claim already used
   by `createDocument` / `rename` / `move`. No new entitlement.

## Confirmed scope decisions (2026-06-05)

| Decision | Choice | Consequence |
|---|---|---|
| Save model | **Manual `Cmd-S` only** | No autosave debounce; data-loss window is user-controlled. Autosave deferred to Future. |
| Edit layout | **Read/Edit toggle** (not split) | Edit = full-width source; Read = full-width preview. No `HSplitView`. Split live-preview deferred to Future. |
| Syntax highlighting | **Dependency-backed highlighter** | Promoted from Future to **Phase 3**. SPM dependency must be added to `Package.swift` **and** the Xcode project (pbxproj package reference). |
| Inbox item editing | **Explicit read-only** | Editor entry point only on indexed documents. The inbox branch keeps only `Open in Editor` (external). |

---

## Phases

### Phase 0 — Read/Edit toggle + inert source view (shippable scaffold)

**Goal:** stand up the toggle and the `NSTextView` wrapper **without touching any write
path**. Mergeable on its own.

| | |
|---|---|
| New file | `Sources/HTMLGraph/Views/DocumentSourceEditor.swift` (NSViewRepresentable) |
| Changed | `Sources/HTMLGraph/Views/ReaderPane.swift` |
| pbxproj | register `DocumentSourceEditor.swift` (see pbxproj section) |

```swift
struct DocumentSourceEditor: NSViewRepresentable {
    @Binding var text: String           // bound to EditorSession.currentText (Phase 2)
    let isEditable: Bool                // false in Phase 0
    var onEdit: (() -> Void)? = nil     // fires only on USER input, not programmatic reload
    func makeNSView(context: Context) -> NSScrollView { /* NSTextView, usesFindBar=true, monospaced, no rich text */ }
    func updateNSView(_ nsView: NSScrollView, context: Context) { /* guard isProgrammaticUpdate to keep undo clean */ }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, NSTextViewDelegate { var isProgrammaticUpdate = false }
}
```

- In `ReaderPane`'s `selectedDocument` branch header (`ReaderPane.swift:106-144`), add a
  `Read | Edit` segmented `Picker` next to `Open in Editor`.
- `@State private var editorMode: EditorMode = .read`. **Reset to `.read` whenever
  `sidebarSelection` changes** (establish the stale-editor-avoidance habit now, via
  `.onChange(of: appState.sidebarSelection)`).
- In Edit mode, render `DocumentSourceEditor(isEditable: false, ...)` instead of
  `documentWebView`. The inbox branch (`ReaderPane.swift:43-105`) is left untouched —
  **inbox items stay read-only** (decision).

**Proof tests:** a `WebResourcePolicyTests`-style assertion that the toggle changes
neither `WebViewIdentity` nor the security policy.

---

### Phase 1 — Incremental single-document reindex (HTMLGraphCore, the spine)

**Goal:** patch one file's `title` / `edges` / `backlinks` / `unresolvedLinks` into an
existing `VaultIndex` without a full vault rescan. Pure logic, no UI dependency,
SPM-auto-discovered.

| | |
|---|---|
| Changed | `Sources/HTMLGraphCore/VaultIndexer.swift` |
| New test | `Tests/HTMLGraphCoreTests/IncrementalReindexTests.swift` (SPM auto-discovers; no pbxproj) |

```swift
extension VaultIndexer {
    /// Re-parse a single changed file against an existing index and return a patched
    /// VaultIndex. IN-PLACE content edits only — file create/delete must fall back to
    /// the caller's full reindex.
    public func reindexDocument(
        _ existing: VaultIndex,
        changedRelativePath: String,
        vaultURL: URL
    ) throws -> VaultIndex
}
```

**Mandatory refactor to prevent drift** — extract these from `indexVault` into shared
helpers so full and incremental paths run **identical code**:

- (a) per-file `DocumentNode` build (title / `contentHash` / `lastModified`),
- (b) the `sourceId#link-<ordinal>` edge-extraction loop (`VaultIndexer.swift:39-55`),
- (c) the **three-way status mapping** `targetId = (status == .resolved || status ==
  .sameDocument) ? targetPath : nil` (`:48`),
- (d) grouping — backlinks from `.resolved` only, unresolved from `.unresolved` only,
  with `.sameDocument` excluded from **both** (`:58-63`),
- (e) `sortedGroups` (`:112-120`).

`reindexDocument` algorithm:

1. Re-read **only** `changedRelativePath` → recompute its `DocumentNode`.
2. Re-normalize **only this file's** outgoing links using
   `knownIds = Set(existing.documents.map(\.id))`. (In-place edits don't change the file
   set, so other files' resolution status is unchanged.)
3. Drop `edges.filter { $0.sourceId == changedRelativePath }`, append the new edges.
4. Re-group backlinks / unresolved from the full edge list — `O(edges)`, **not** `O(files)`
   on disk.

**Drift-guard test (release blocker):** for the same on-disk state,
`reindexDocument(existing, path)` must equal `indexVault(...)` on **every field except
`lastIndexedAt`** (documents / edges / backlinks / unresolvedLinks, ordering included).
Cases: ① title change, ② a new link resolves to an existing doc, ③ a link flips to
unresolved, ④ **a fragment-only (`#sec`) `sameDocument` link appears in neither backlinks
nor unresolved**. The equality helper must explicitly exclude `lastIndexedAt` (else it
always fails; loosen it wrong and it stops catching drift).

---

### Phase 2 — EditorSession + manual save path (incremental apply, no view destruction)

**Goal:** dirty tracking, atomic write, and incremental index apply done **synchronously
on the main actor** so we bypass `beginSession` → selection / scroll / preview stay put.

| | |
|---|---|
| New file | `Sources/HTMLGraph/EditorSession.swift` (`@MainActor ObservableObject`) |
| Changed | `Sources/HTMLGraph/AppState.swift`, `Sources/HTMLGraph/Views/ReaderPane.swift` |
| pbxproj | register `EditorSession.swift` |

```swift
@MainActor final class EditorSession: ObservableObject {
    @Published private(set) var baselineText: String   // exact bytes loaded into the editor
    @Published var currentText: String
    var isDirty: Bool { currentText != baselineText }
    private(set) var baselineHash: String              // index-style SHA256(Data(string.utf8))
    private(set) var baselineMTime: Date
    let documentId: String                             // vault-relative id, re-resolved at save
    func seed(fromDiskAt url: URL) throws              // String(contentsOf:.utf8) → baseline
    func markSavedNow(hash: String, mtime: Date)       // reset baseline after a successful save
}
```

`AppState.saveDocumentEdits`:

```swift
@MainActor func saveDocumentEdits(id: String, newText: String) throws {
    // 1. Re-derive absolutePath from id (DON'T trust a captured stale DocumentNode):
    //    vaultURL.appendingPathComponent(id) + containment check (reject ".." in id).
    // 2. Conflict pre-check: re-read disk → compute index-style string hash → compare to baselineHash.
    // 3. Atomic write: try newText.write(to: url, atomically: true, encoding: .utf8)
    // 4. Defuse an in-flight full reindex: bump indexingGeneration (stale result discarded by finishIndexing).
    // 5. let patched = try VaultIndexer().reindexDocument(index!, changedRelativePath: id, vaultURL: vaultURL)
    // 6. self.index = patched          // NO beginSession, NO isIndexing toggle, NO selection reset
    // 7. graph.json best-effort re-export (same logger pattern as finishIndexing)
    // 8. session.markSavedNow(hash:, mtime:)
}
```

**★ Hash parity (required):** the baseline / conflict hash must match
`DocumentNode.contentHash` exactly — `SHA256(Data(decodedString.utf8))`
(`VaultIndexer.swift:107-110`). Hashing raw file bytes (BOM / CRLF) or a stale index
node's hash produces phantom conflicts.

`ReaderPane` changes:

- Own `@StateObject private var editor: EditorSession`; `seed` on entering Edit mode.
- **Preview reload:** add `contentHash` to `webViewIdentity(for:)` (`:355-362`) — the same
  mechanism the inbox identity already uses (`:364-372`). After save, `index` updates →
  `selectedDocument.contentHash` changes → `.id(identity)` changes → `makeNSView` rebuild
  → loopback GET (`Cache-Control: no-store`) serves the new bytes. With **toggle layout**
  this matters when switching Edit → Read after a save.
- Save via `Cmd-S` and a toolbar button. Saving keeps the **current document** (no forced
  jump back to Read).

**Proof tests:**

- `EditorSession`: `isDirty` transitions; baseline reset after save.
- `saveDocumentEdits`: byte-exact round-trip (CRLF / BOM preserved); title + link change
  produces the new edge / backlink in `index`; the `index` update does **not** reset
  `sidebarSelection`.
- Identity test (extend `WebResourcePolicyTests`): the **document** identity now changes
  when `contentHash` changes (currently only inbox does), and still changes on
  trust / network change.
- Conflict: external change after baseline capture → save is blocked and routes to
  Overwrite / Reload / Cancel.

---

### Phase 3 — Syntax highlighting (dependency) + Find / keyboard

**Goal:** real HTML syntax highlighting via a maintained dependency, plus editor
keyboard affordances.

| | |
|---|---|
| Changed | `Package.swift`, `Sources/HTMLGraph/Views/DocumentSourceEditor.swift`, `ReaderPane.swift` |
| pbxproj | **add the SPM package reference + product to the app target** (heavier than a source-file add — see below) |

**Library recommendation (confirm before starting Phase 3):**

- **Primary: [Highlightr](https://github.com/raspu/Highlightr)** — wraps highlight.js via
  **JavaScriptCore** (a `JSContext`, **not** a `WKWebView`), so it stays sandbox-safe and
  introduces **no document-JS / Trusted-mode coupling**. It ships a `CodeAttributedString`
  (an `NSTextStorage` subclass) that drops straight into the Phase-0 `NSTextView`. Themes
  included. _Caveat:_ it re-highlights the whole string by default — throttle / cap for
  multi-MB files (see Data-loss guards).
- **Higher ceiling: [Neon](https://github.com/ChimeHQ/Neon) + SwiftTreeSitter +
  tree-sitter-html** — native, incremental, better on large files, but more integration
  (grammar packaging). Choose this if large-file editing is a priority.

Highlighting must honor the critique constraint: **never re-tag the whole file on every
keystroke** for large files — use the storage delegate to tag edited line ranges, or
throttle Highlightr above a size threshold.

- Wire `Cmd-S` (save), `Cmd-Z` / `Cmd-Shift-Z` (native `NSTextView` undo), `Cmd-F`
  (`usesFindBar` / `performTextFinderAction`) through the NSViewRepresentable responder
  chain — **view-local, not an app-wide `Commands` group** (avoid misfire when no editor
  is present).

**Proof tests:** Find-bar toggle; undo round-trip; highlighting does not corrupt the
underlying string (highlight is attributes-only); large-file throttle path is exercised.

---

## pbxproj registration (every new `.swift` + the SPM dependency)

Source files — for `DocumentSourceEditor.swift` and `EditorSession.swift`, add to
`HTMLGraph.xcodeproj/project.pbxproj`:

| Entry | Where |
|---|---|
| `PBXFileReference` | follow the existing sequential hex-id scheme |
| `PBXBuildFile` | likewise |
| PBXGroup children | `DocumentSourceEditor` → the Views group; `EditorSession` → the HTMLGraph group |
| Sources build phase | the app target's Sources phase |

SPM dependency (Phase 3) — heavier: add an `XCRemoteSwiftPackageReference`, an
`XCSwiftPackageProductDependency`, and the product to the app target's
`Frameworks`/`packageProductDependencies`. Add the same dependency to `Package.swift`.

**Verification (required):** both `swift build` **and**
`xcodebuild -scheme HTMLGraph build` must be green. SwiftPM auto-discovers source files
and resolves `Package.swift`; Xcode does **not** — a missing pbxproj entry breaks
`xcodebuild` / TestFlight only (the recorded trap in `MEMORY.md`). Core test files are
SPM-auto-discovered (no pbxproj needed unless run through an Xcode test target).

---

## Data-loss / race guards (critique mustFix → concrete guards)

| Risk | Guard |
|---|---|
| Full reindex destroys the editor subtree (`isIndexing=true` → `ReaderPane.swift:40` swaps in `ProgressView`) | `saveDocumentEdits` never calls `beginSession` (incremental path). When dirty, gate `beginSession` / `openVault` / `acceptInboxItem` / all sidebar mutators behind a **single `appState.hasUnsavedEdits` check** (Save / Discard / Cancel prompt first). Editor text lives in `EditorSession` (`@StateObject`), not view `@State`, so it survives transient re-evaluation. |
| An in-flight full reindex overwrites the incremental patch (`finishIndexing` is gated only by `indexingGeneration`, `:539`) | `saveDocumentEdits` bumps `indexingGeneration`, so the stale full result is dropped by `finishIndexing`'s guard. (Alternatively `await`/cancel `indexingTask` first.) |
| 2s inbox poll resets selection / re-renders mid-edit | Documents aren't poll targets (they live only in the index). Inbox in-app editing is **out of scope** (read-only decision). Insulate the editor subtree from the poll's `@Published inboxItems` updates so the cursor isn't reset. |
| Conflict check uses a stale index-node hash → phantom / missed conflicts | Baseline = the **exact bytes loaded into the editor**, hashed index-style (`SHA256(Data(string.utf8))`). Re-read disk + same hash right before write. After a successful save, reset baseline to the just-written string-hash (the atomic write changes mtime — don't let that alone trigger a phantom conflict). Conflict dialog default focus = **non-destructive** (Reload / Cancel). |
| Move/rename changes `path` (= id); writing to a stale `absolutePath` | At save, re-derive `absolutePath` from `id` via `vaultURL.appendingPathComponent` + the server's containment check (reject `..`). Don't trust a captured `DocumentNode.absolutePath`. |
| Atomic write / torn reads | `write(to:atomically:true,encoding:.utf8)` → the loopback GET only ever sees complete old-or-new bytes. (Non-atomic external writes remain a pre-existing, out-of-scope risk.) |
| `WKWebView` rebuild discards unsaved text | The `contentHash` identity change rebuilds **only the preview pane**. The source `NSTextView` is not tied to that identity, so unsaved text survives. Don't jostle the identity needlessly within a session (bump once, on save). |
| Loss on quit (no `NSApplicationDelegate` today; see `HTMLGraphApp.swift`) | Add an `NSApplicationDelegateAdaptor` → `applicationShouldTerminate` returns `.terminateLater` when dirty, then prompts Save / Discard. Same on window close. **Prove with a real test, not prose.** |
| Undo pollution | The programmatic baseline push in `updateNSView` is wrapped by the `isProgrammaticUpdate` flag so it doesn't register an `NSUndoManager` action. Clear the undo stack on "discard my changes & reload" after a conflict. |
| CRLF / BOM normalization | Guarantee the `NSTextView` read→edit→write path does no CRLF→LF or NFC↔NFD transform. Add a byte-preservation round-trip test for a CRLF file (else untouched lines get re-hashed, polluting external diff / sync). |
| Crash / force-quit | Manual-save-first keeps the loss window under user control. (Optional future: a periodic draft journal while dirty — out of scope.) |

---

## Security / sandbox

- **Source editing stays in Safe mode.** `DocumentSourceEditor` is a plain-text
  `NSTextView` — no `WKWebView` is instantiated, so JavaScript / Trusted mode / network
  never come into play. The `allowsContentJavaScript` gate and `WKContentRuleList` are
  bypassed while editing and re-apply unchanged only when the preview rebuilds in
  `makeNSView`. **Zero new trust surface, zero new entitlement.**
- **Writes extend an existing write surface.** Reuse the `accessedVaultURL`
  security-scoped claim used by `createDocument` / `rename` / `move`. Because
  `releaseAccess` drops the claim on vault switch (`AppState.swift:508-510`), any future
  autosave must cancel on switch.
- **Why WYSIWYG was rejected (security angle).** `contentEditable` + `execCommand`
  requires JS inside the `WKWebView`, coupling editing to Trusted mode and to the
  document's own scripts; writing a script-stripped DOM back to disk would permanently
  delete `<script>` / handlers / comments the user never asked to remove (data loss), and
  a `loadHTMLString` edit build leaves the loopback-token origin, breaking the network
  gate and relative-asset resolution. Source editing avoids all of it.

---

## Out of scope / future

- **Autosave** (debounced) — deferred; if added, must cancel on vault switch / quit /
  selection change, no-op during an unresolved conflict, and surface write errors inline.
- **Split live-preview** (`HSplitView { source ; preview }`) — deferred; toggle ships first.
- **WYSIWYG** — rejected, or only ever as a separate opt-in "visual edit (HTML may be
  reformatted)" mode (never default, never autosave).
- **Inbox item in-app editing** — out of scope (read-only); inbox items remain editable
  only via external `Open in Editor`.
- Multi-file / tabbed editing, FSEvents/NSFilePresenter live file watching, crash draft
  journal, non-UTF-8 / charset re-encoding preservation, deeper VoiceOver a11y.

---

## Verified ground

Load-bearing claims checked against source: `ReaderPane.swift` (identity 14-30,
`webViewIdentity` 355-372, `isIndexing` branch 40); `AppState.swift` (`beginSession`
439-498 with synchronous reset 457-460, `finishIndexing` 538-573 with generation guard
539, `refreshInbox` 608-619, `accessedVaultURL` / `releaseAccess` 216 · 508-510);
`VaultIndexer.swift` (edge-id 46, three-way status 48, backlinks/unresolved grouping
58-63, string sha256 107-110).
