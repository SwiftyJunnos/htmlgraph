# Remote Vault over SSH — In-app SFTP filesystem layer

Status: M1–M7 + M9 SFTPFileSystem done (compiles vs Citadel, both build systems green).
Next: M8 (wire remote vaults into AppState — connect UI / identity / Keychain). Owner: Junnos

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

- **M6 — Editor save path. ✅ DONE (2026-06-24).**
  `VaultIndexer.reindexDocument(_:changedRelativePath:fileSystem:) async` (+ `vaultURL:`
  convenience); `AppState.beginEditing` / `saveEditorBuffer` / `writeEditorText` /
  `resolveConflictByOverwriting` are `async` over the FS; `editorFileURL`+`modificationDate(of:)`
  replaced by `editorRelativePath` + `fileSystem.metadata` (mtime). `EditorGuard.confirmLeavingEditor`
  is `async`; all **17 call sites** restructured: the sync `applicationShouldTerminate` quit
  guard uses `.terminateLater` + `reply(toApplicationShouldTerminate:)` (fast-path terminateNow
  when nothing unsaved); ReaderPane setMode/selection/external-editor guards `await` in their
  (already async) Tasks; HTMLGraphApp menus, ContextPane, ContentView, VaultSidebar
  `SidebarActions` wrap body in `Task { guard await … }`. Content-hash conflict detection ports
  unchanged. **Adversarial review (workflow) found + fixed a re-entrancy data-loss blocker**:
  the pre-M6 save was a synchronous atomic critical section; the async awaits opened a window
  where a keystroke during the write/reindex was discarded by the final `editorBuffer` reset —
  fixed by reconciling on completion (baseline = written bytes, keep live `currentText`, guarded
  by `documentId`). Verified: `swift test` (132) + `xcodebuild`. Remaining local-isms (deferred
  to M10): `directoryExists` in `openRecent` (bookmark path) and `finishIndexing`'s
  pendingEmptyFolders pruning still use `FileManager`.

- **M7 — Preview server via FS + per-request concurrency. ✅ DONE (2026-06-24).**
  `VaultHTTPResponder` holds a `VaultFileSystem` (+ `vaultURL:` convenience init) and
  `respond(...)` is `async`, reading via `metadata`/`readData`/`readRange` (range reads →
  `readRange`); `fileURL(forTarget:)`+`readFile` replaced by `relativePath(forTarget:token:)`.
  `VaultHTTPServer.start(fileSystem:)` (+ `vaultURL:` convenience — AppState still calls the
  latter); each request's response is generated in a `Task` off the serial queue so a slow
  remote read can't block other connections. `VaultHTTPServerTests` responder tests await.
  `VaultResourceSchemeHandler` (the `htmlgraph://` handler) is **dead code** — never registered
  (loopback HTTP replaced it); left untouched except its still-used static `mimeType(for:)`.
  Remaining: UI gating (hide Reveal-in-Finder / external-editor for remote vaults) deferred to
  M8/M10. Verified: `swift test` (132) + `xcodebuild`.

- **M8 — Vault identity + selection model.**
  Generalize `RecentVault` / `VaultIndex.vaultId` to a `VaultRef` (local URL **or**
  remote host+path). A "Connect to Remote…" dialog; credentials in Keychain; host-key TOFU.

- **M9 — `SFTPFileSystem` implementation. IN PROGRESS.**
  - ✅ **Citadel added** (`Package.swift` → `orlandos-nl/Citadel` from 0.7.0; resolved to
    **0.12.1**, pulls swift-nio/swift-crypto/swift-nio-ssh/BigInt). `swift build`/`swift test`
    (132) + `xcodebuild` all green with it (Citadel not yet imported).
  - **Citadel API gathered** (from `.build/checkouts/Citadel`, v0.12.1):
    - `SSHClient.connect(host:port:authenticationMethod:hostKeyValidator:reconnect:algorithms:protocolOptions:group:channelHandlers:connectTimeout:) async throws -> SSHClient`
    - `sshClient.openSFTP(logger:) async throws -> SFTPClient`
    - `SFTPClient`: `listDirectory(atPath:) -> [SFTPMessage.Name]`, `getAttributes(at:) -> SFTPFileAttributes`,
      `openFile(filePath:flags: SFTPOpenFileFlags, attributes: .none) -> SFTPFile`,
      `createDirectory(atPath:)`, `remove(at:)`, `rmdir(at:)`, `rename(at:to:flags:)`,
      `getRealPath(atPath:) -> String`, `close()`, `isActive`. (all `async throws`)
    - `SFTPFile`: `readAll() -> ByteBuffer`, `read(from:length:) -> ByteBuffer`,
      `write(_ ByteBuffer, at:)`, `readAttributes() -> SFTPFileAttributes`, `close()`.
    - STILL TO READ before coding: `SFTPMessage.Name` shape (filename + attrs for enumerate),
      `SFTPFileAttributes` (size, mtime, isDirectory via permissions/type), `SFTPOpenFileFlags`
      cases, `SSHAuthenticationMethod` (.passwordBased / .rsa/ed25519 publicKey),
      `SSHHostKeyValidator` (`.acceptAnything()` for TOFU first pass).
  - ✅ **`SFTPFileSystem` implemented** (`Sources/HTMLGraphCore/SFTPFileSystem.swift`): a
    `Sendable` struct over an `SFTPConnection` actor (lazily connects via `SSHClient.connect`
    + `openSFTP()`, reuses the live `SFTPClient`). Maps every `VaultFileSystem` method —
    recursive `enumerateFiles` (stack over `listDirectory`, skip `.`/`..`/hidden), `readData`=
    `openFile(.read)+readAll`, `readRange`=`read(from:length:)`, `metadata`/`exists`=
    `getAttributes` (isDir/isRegular via POSIX mode bits), `writeData` atomic = temp write +
    remove + `rename` (non-atomic window — hardening TODO), `move`=`rename`, `copy`=read+write,
    `trash`=move into `.htmlgraph/.trash/` (unique-suffixed), `remove`/`rmdir`, `createDirectory`
    = mkdir-p, `vaultIdentity`=`sftp://user@host:port/root`, `absolutePath`=nil. Auth: **password
    only** for now (`SFTPCredential.password`; key auth is a hardening TODO — the OpenSSH
    key-parsing API needs pinning). `SSHHostKeyValidator.acceptAnything()` (TOFU is a TODO).
  - ✅ **Citadel wired into `project.pbxproj`** (SwiftSoup's 6-entry pattern on HTMLGraphCore)
    + `SFTPFileSystem.swift` registered. Both `swift test` (135, +3 SFTP construction tests) and
    `xcodebuild` (resolves Citadel 0.12.1, compiles + links) green.
  - **Known limits (→ M10)**: no integration test (needs a live `sshd`; pure logic unit-tested);
    `disconnect()` only closes the SFTP client (SSHClient is non-Sendable, released not closed);
    concurrent first-use can open two connections; atomic-write window; password-only auth.

- **M10 — Hardening + cache relocation.**
  Sidecars/index cache to `~/Library/Caches` for remote; surface connection-loss instead of
  silently indexing an empty vault; timeouts everywhere; perf pass (pipelined reads).

## Verification strategy

Each milestone is a behavior-preserving step verified by the existing test suite plus new
backend tests. Because the Xcode project has **no test targets** (tests run via SwiftPM),
new test files need no `project.pbxproj` entry — but every new **source** file in
`HTMLGraphCore`/`HTMLGraph` must be registered (classic pbxproj). Verify both build systems:
`swift test` and `xcodebuild -scheme HTMLGraphCore build`.
