# Remote Vault over SSH — In-app SFTP filesystem layer

Status: M5 done — file-op mutations + inbox accept async. Next: M6 (editor save path).
Started: 2026-06-24
Owner: Junnos

## Goal

Let HTMLGraph open a vault that lives on a remote host reachable over SSH, with **all
existing features working** (indexing, loopback-HTTP preview, in-app HTML editor with
conflict detection, file ops, inbox, on-device embeddings).

## Why this approach (decision)

The app is a sandboxed macOS app (`com.apple.security.app-sandbox` = true; entitlements:
`files.user-selected.read-write`, `network.client`, `network.server`). Every feature is
built on local `file://` URLs + `FileManager` + security-scoped bookmarks. There is no
"remote" concept.

Five approaches were evaluated (see the feasibility analysis from 2026-06-24). Mount-based
options (macFUSE, FUSE-T, SMB/NFS) and SSH-sync (Mutagen) all keep the app code unchanged
but each has a disqualifier for a *first-class* remote feature: macFUSE needs a kernel
extension (Apple-Silicon Reduced Security + reboots, impossible from a sandboxed app);
FUSE-T/SMB are operationally fragile mounts with broken `trashItem`, no timeouts, and stale
security-scoped bookmarks; Mutagen is a synced copy, not live.

**A native in-app SFTP backend is the only path that is both live and sandbox-pure**: an
SFTP socket is satisfied entirely by `network.client` (already entitled). It never touches
the file-access sandbox, FUSE, mounts, or security-scoped bookmarks. The cost is a large
refactor of the app's filesystem layer — which is exactly what this plan stages.

## Architecture: the `VaultFileSystem` seam

Introduce one protocol that abstracts every filesystem operation the app performs on a
vault. Two backends conform:

- `LocalFileSystem` — behavior-preserving, backed by `FileManager` (today's behavior).
- `SFTPFileSystem` — later milestone, backed by an SSH/SFTP client (Citadel / SwiftNIO).

Design decisions:

1. **Vault-relative, "/"-separated paths everywhere.** This is the identity the app already
   uses (`DocumentNode.id` *is* the relative path). The conforming instance owns the root
   and enforces containment (a `..` escape throws `outsideVault`, never touches disk).
2. **`async` protocol.** A remote backend does network I/O; a synchronous API would force it
   to block — fatal on `@MainActor`. `LocalFileSystem`'s `nonisolated async` methods run off
   the caller's actor (cooperative pool), so even local file work leaves the main thread for
   free. The SFTP backend owns its own connection actor + timeouts.
3. **`trash` is a protocol op, not `FileManager.trashItem`.** Local → the user's Trash;
   remote → relocate into a vault-internal trash area. Callers don't care which.
4. **Atomic / create-only writes are expressed as `VaultWriteOptions`**, mapped by each
   backend to its durability/exclusivity primitives (local: temp+rename; SFTP:
   temp+`posix-rename@openssh.com` + read-back verify).

### What stays out of the protocol

- **Vault selection + identity.** Local uses `NSOpenPanel` + security-scoped bookmarks
  (`RecentVault.bookmarkData`). Remote identity is `host + port + remotePath + credentials`
  (Keychain). This is a separate identity model (Milestone 6), not a per-file op.
- **`DocumentNode.absolutePath` and the local-only UI actions that read it** — "Reveal in
  Finder", "Open in Browser", "Open in external editor" (`ReaderPane`, `VaultSidebar`,
  `SidebarCommands`). These are inherently local (`NSWorkspace`). For a remote vault they
  must be hidden/disabled (Milestone 5), not abstracted.

## Filesystem coupling inventory (audited 2026-06-24)

Operations the protocol must cover, by call site:

- **Enumerate** (recursive, skip hidden): `VaultIndexer.htmlFiles`, `InboxScanner.htmlFiles`.
- **Read text (UTF-8)**: indexer (×2 per file — see efficiency note), inbox scanner, editor
  load (`AppState.beginEditing`), conflict re-read (`saveEditorBuffer`), semantic body loader.
- **Read data / range**: `VaultHTTPServer` (200 full, 206 range via `FileHandle.seek`),
  `VaultResourceSchemeHandler`, `VaultIndexCache.load`, `VaultEmbeddingStore.load`.
- **Stat** (mtime / size / isRegularFile / exists / isDirectory): indexer, inbox, HTTP
  server, `AppState.directoryExists`/`uniqueDestination`/folder-pruning, cache, embedding store.
- **Write (atomic)**: editor save (`writeEditorText`), stub creation, `VaultIndexCache`,
  `VaultIndexExporter`, `VaultEmbeddingStore`.
- **Write (create-only)**: `VaultAgentGuideWriter` (`.withoutOverwriting`).
- **createDirectory / move / copy / trash / remove / contentsOfDirectory**: `AppState`
  file ops (move/rename/trash/duplicate/create/createFolder/removeEmptyFolderIfNeeded),
  `InboxAccepter`.

## Cross-cutting defects to fix along the way (worth doing regardless of remote)

1. `trashItem` has no fallback → breaks on any non-local volume (`AppState:1053`,`:1366`).
2. **No timeouts** on any FS read/enumerate path; **inbox poll `refreshInbox()` runs on the
   `@MainActor`** (`AppState:1442`) → an SSH stall freezes the UI directly.
3. `VaultIndexer.indexVault` **reads each file twice** (`:30` and `:37`) — read once, derive
   title+hash+edges from one buffer → ~halves index I/O on any backend.
4. Sidecars (`.htmlgraph/graph.json`, `embeddings.json`) live inside the vault → consider a
   local cache (`~/Library/Caches`, keyed by vault identity) for remote vaults.

## Milestones

- **M1 — Protocol + reference backend. ✅ DONE (2026-06-24).**
  `VaultFileSystem` protocol + value types (`VaultFileMetadata`, `VaultFileEntry`,
  `VaultWriteOptions`, `VaultFileSystemError`) in `Sources/HTMLGraphCore/VaultFileSystem.swift`;
  `LocalFileSystem` reference backend in `Sources/HTMLGraphCore/LocalFileSystem.swift`; 20
  unit tests in `Tests/HTMLGraphCoreTests/LocalFileSystemTests.swift`. No consumer migrated
  → zero behavior change. Both files registered in `project.pbxproj` (fileRef `…0057`/`…0058`,
  buildFile `…0157`/`…0158`). Verified: `swift test` green (132 Core + app tests) **and**
  `xcodebuild -scheme HTMLGraph` BUILD SUCCEEDED. Notes for later backends:
  `enumerateFiles` must iterate via `nextObject()` (the `DirectoryEnumerator` `Sequence`
  iterator is unavailable from async); `writeData` does NOT create parents (callers
  `createDirectory` first — matches existing call sites); `LocalFileSystem.absolutePath(for:)`
  is the local-only affordance for `DocumentNode.absolutePath` (returns nil for remote).

- **M2 — Migrate the embedding subsystem. ✅ DONE (2026-06-24).**
  `VaultEmbeddingStore.load/save` are now `async` and take `fileSystem: VaultFileSystem`
  (read/write `.htmlgraph/embeddings.json` via `VaultEmbeddingStore.relativePath`; `save`
  dropped its `-> URL` return). `SemanticIndexer.refresh/embedRecord/embed` take a
  `fileSystem`; `diskBodyTextLoader` is now `(DocumentNode, VaultFileSystem) async throws ->
  String` reading body via `fileSystem.readText(at: node.path)` — the `node.absolutePath`
  read is gone, so the subsystem has **zero direct FS coupling** (verified by grep). Callers:
  `AppState.rebuildEmbeddingIndex/refreshEmbedding/persistEmbeddingIndex` construct
  `LocalFileSystem(root: vaultURL)`. Tests updated to pass a `LocalFileSystem`. Verified:
  `swift test` green (132 Core + app) **and** `xcodebuild` BUILD SUCCEEDED. No pbxproj change
  (no new files). Note: `node.path == node.id` in production (both the vault-relative path);
  the disk loader uses `node.path`.

- **M3 — Migrate `VaultIndexer` (the index spine). ✅ DONE (2026-06-24).**
  `indexVault(fileSystem:) async` enumerates/reads/stats through the FS; `indexVault(at:)`
  is an async convenience wrapping `LocalFileSystem(root:)`. Added protocol members
  `vaultIdentity` (→ `VaultIndex.vaultId`) and `absolutePath(for:)` (local-only, nil default;
  `LocalFileSystem` returns the on-disk path). Folded in the **read-once** fix (each file read
  once; mtime from the enumeration — no second read, no extra stat) and removed
  `htmlFiles`/`relativePath` helpers. `documentNode` now takes `(relative, html, absolutePath,
  lastModified)`. Byte-for-byte equivalence preserved — `IncrementalReindexTests` green.
  Caller: `AppState.beginSession` (already in `Task.detached`). Tests across
  `VaultIndexerTests`/`IncrementalReindexTests`/`EditorSessionTests`/`AppStateSecurityPolicyTests`
  made `async`. **Scope note:** `reindexDocument` stays synchronous for now (its caller
  `writeEditorText` is the editor-save path → migrated in M4 with the AppState async refactor).
  `InboxScanner` ALSO deferred to M4 because its callers (`beginSession`/`refreshInbox`/the
  inbox poll) are synchronous `@MainActor` flows that must go async together. Verified:
  `swift test` (both bundles) + `xcodebuild` BUILD SUCCEEDED.

- **M4 — Readers (`InboxScanner`) + sidecar writers async. ✅ DONE (2026-06-24).**
  `InboxScanner.scanInbox(fileSystem:) async` (+ `at:` convenience); `VaultIndexExporter.export`
  and `VaultAgentGuideWriter.writeIfMissing/regenerate` → `async` over the FS (+ `vaultURL:`
  convenience returning a URL where tests need it; `export(fileSystem:)` returns Void). Added
  `VaultIndexExporter.relativePath`. AppState: `refreshInbox()` is `async`; sidecar export,
  agent-guide write, and inbox scan in `finishIndexing` are **Task-wrapped (off-main)**, as is
  `regenerateAgentGuide()` (dropped its unused `-> Bool`). **Inbox-poll main-thread freeze
  fixed** — the 2s poll now `await`s the async `refreshInbox`, whose scan runs off-main via
  `LocalFileSystem`'s nonisolated async. `acceptInboxItem`/`trashInboxItem` update the inbox
  with a synchronous in-memory `inboxItems.removeAll` (a re-scan is async) — behavior + test
  assertions preserved. SwiftUI-facing method signatures unchanged (approach a). `VaultIndexCache`
  intentionally NOT migrated — it's an inherently local index cache (stays local even for remote
  vaults; see M9 cache relocation). Verified: `swift test` (132 Core + app) + `xcodebuild`.

- **M5 — File-op mutations + inbox accept (the SwiftUI-async ripple). ✅ DONE (2026-06-24).**
  `AppState` file ops (createDocument×2 / move / rename / trash / duplicate / createFolder /
  addToVault / acceptInboxItem / trashInboxItem) are `async` over the FS; helpers
  (`uniqueRelativeDestination`, `uniqueFolderRelativePath`, `removeEmptyFolderIfNeeded`) async;
  URL-based `uniqueDestination` removed. `InboxAccepter.accept` rewritten to
  `accept(_:toRelativePath:fileSystem:) async` (relative-path containment checks); AppState
  converts the picker URL → relative via `vaultRelativePath`. SwiftUI call sites
  (VaultSidebar `SidebarActions`, ContextPane, ContentView) wrap the final call in `Task`;
  sync guards/prompts run first. Tests `await` the ops so synchronous assertions hold.
  Note: `LocalFileSystem.trash` still uses `FileManager.trashItem`; the remote-Trash fallback
  lands with the SFTP backend (M9). Verified: `swift test` (132) + `xcodebuild`.

- **M6 — Editor save path.**
  `VaultIndexer.reindexDocument` → `async` over the FS; `AppState.beginEditing` /
  `saveEditorBuffer` / `writeEditorText` / conflict resolution + `editorFileURL` /
  `modificationDate` through the FS. `saveEditorBuffer() -> Bool` becomes `async`, so its
  callers (ReaderPane ⌘S, `EditorGuard` in EditorSession) and `beginEditing` (whose `Bool` the
  reader uses in an `if`) must thread `await`/`Task`. Content-hash conflict detection ports
  unchanged.

- **M7 — Migrate the preview servers + UI gating.**
  `VaultHTTPServer` responder and `VaultResourceSchemeHandler` read through the FS (range
  reads → `readRange`). Add a connection pool / concurrency so per-request remote I/O doesn't
  serialize. Hide/disable local-only UI actions (Reveal in Finder, external editor) for
  remote vaults.

- **M8 — Vault identity + selection model.**
  Generalize `RecentVault` / `VaultIndex.vaultId` to a `VaultRef` (local URL **or**
  remote host+path). A "Connect to Remote…" dialog; credentials in Keychain; host-key TOFU.

- **M9 — `SFTPFileSystem` implementation.**
  Citadel/SwiftNIO backend: connection actor, pooling, timeouts, reconnect/backoff,
  atomic write (temp + `posix-rename@openssh.com` + read-back), `trash` = move to vault
  `.htmlgraph/.trash`, metadata/size cache to cut round-trips.

- **M10 — Hardening + cache relocation.**
  Sidecars/index cache to `~/Library/Caches` for remote; surface connection-loss instead of
  silently indexing an empty vault; timeouts everywhere; perf pass (pipelined reads).

## Verification strategy

Each milestone is a behavior-preserving step verified by the existing test suite plus new
backend tests. Because the Xcode project has **no test targets** (tests run via SwiftPM),
new test files need no `project.pbxproj` entry — but every new **source** file in
`HTMLGraphCore`/`HTMLGraph` must be registered (classic pbxproj). Verify both build systems:
`swift test` and `xcodebuild -scheme HTMLGraphCore build`.
