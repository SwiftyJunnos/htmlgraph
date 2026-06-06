# HTMLGraph AI-Native — Phase 0: Offline Semantic Search

_Date: 2026-06-05_

> This is **Phase 0 of the AI-Native / MCP roadmap**. It ships the retrieval
> substrate that every later AI phase (in-app copilot RAG, AI-suggested edges,
> MCP server `semantic_search` tool) depends on — while adding **zero network,
> zero new write paths, zero new entitlements, and zero new trust surface**.
> It stays entirely in Safe mode and is fully reversible (delete the sidecar).

## Roadmap context

| Phase | Title | Net-new risk surface |
|---|---|---|
| **0 (this doc)** | Offline semantic search | none (read-only, on-device, no egress) |
| 1 | Read-only MCP server (`search_vault`, `get_document`, resources) over the existing loopback transport | loopback listener (already entitled) |
| 2 | MCP write tools (`create_document`→Inbox, `propose_edit`→body splice), human-accepted | Trusted-writes opt-in |
| 3 | In-app copilot (MCP host): on-device Foundation Models default, Claude API opt-in, RAG over Phase 0 index | outbound API (opt-in consent) |
| 4 | AI-native UX: suggested `<a href>` edges, agent-activity Inbox, auto-metadata | per-feature opt-in |

Phase 0 is deliberately the smallest reversible slice: **search notes by meaning,
on-device, re-ranked by the link graph.** No model cost, no MCP, no writes.

## Problem

Today the only search is lexical: `AppState.filteredDocuments` (`AppState.swift:355-364`)
does `title.localizedCaseInsensitiveContains || path.localizedCaseInsensitiveContains`.
It can't find a note by meaning ("내가 X에 대해 내린 결론") unless the query string
literally appears in the title/path. Every later AI feature needs *retrieval* —
finding the right notes to feed a model or an agent — and lexical contains is too
weak to be that substrate. Phase 0 adds **on-device semantic search** layered over,
not replacing, the existing link-graph index.

## Approach decision

Three on-device embedding backends were evaluated (web-researched 2026-06-05):

| Backend | Korean? | Dim | Binary cost | Impl | Verdict |
|---|---|---|---|---|---|
| **`NLContextualEmbedding`** (CJK script model) | **Yes** | 512 | ~0 (assets on-demand) | Low–Med | **Adopt as default** |
| Core ML multilingual-MiniLM-L12-v2 | Yes (50+) | 384 | +120–470 MB in-bundle | High (Swift SentencePiece tokenizer) | Defer to Phase 1 upgrade |
| `NLEmbedding.sentenceEmbedding(for:)` | **No → returns `nil`** | 512 | 0 | Low | **Reject** (English-only) |

**Spine = `NLContextualEmbedding`**, the only built-in Apple option that actually
embeds Korean. The codebase forces the shape of this decision:

1. **Deployment floor is `.macOS(.v14)`** (`Package.swift:7`) — exactly where
   `NLContextualEmbedding` becomes available (macOS 14 / iOS 17). No `#available`
   gymnastics for the floor; but model **assets download on demand**
   (`hasAvailableAssets` / `requestAssets` / `load()`), so there is a one-time
   "preparing search…" step, offline thereafter.
2. **Korean is real here** — the user's notes are Korean/mixed. The older
   `NLEmbedding.sentenceEmbedding(for: .korean)` returns `nil` by design (no Korean
   asset), so it is disqualified. `NLContextualEmbedding`'s CJK model covers Korean
   (WWDC23-10042: "one model for Chinese, Japanese, and Korean").
3. **It outputs per-token vectors** → we **mean-pool** to one 512-d document vector
   ourselves (Apple does not pool). Long docs are chunked (~256 tokens) and the chunk
   vectors mean-pooled. Verify `dimension` at runtime via the model property.
4. **Provider is abstracted behind a protocol** so the Core ML MiniLM swap (Phase 1,
   if Korean quality proves insufficient) is a drop-in, and so unit tests inject a
   deterministic fake instead of the OS model.

Everything is **additive and reversible**: a new hidden sidecar
`<vault>/.htmlgraph/embeddings.json` (alongside `graph.json`), a new search *mode*
toggle, and background re-embed hooks that piggyback the existing index lifecycle.
Delete the sidecar and the feature is gone with no trace in the vault.

## Confirmed scope decisions

| Decision | Choice | Consequence |
|---|---|---|
| Embedding backend | **`NLContextualEmbedding` (CJK)**, behind `EmbeddingProvider` protocol | On-device, multilingual, zero binary cost; Core ML swap deferred |
| Storage | **New hidden sidecar `embeddings.json`** (NOT inside `graph.json`) | `graph.json` schemaVersion=1 contract is **untouched**; indexer's `.skipsHiddenFiles` means no feedback loop |
| Cache key | **`(documentId, contentHash)`** | Re-embed only changed docs; full re-embed is one-time per vault |
| Search surface | **Mode toggle (Title \| Meaning)** next to the existing `.searchable` field | Lexical stays the instant/offline default; semantic is opt-in per query |
| Writes | **None** | Phase 0 never mutates the vault; no `InboxAccepter`/editor path touched |
| Network | **None** | Stays in Safe mode; no new entitlement; zero egress |
| Inbox items | **Out of scope** | Only indexed documents are embedded (Inbox is excluded from the index anyway) |

---

## Phases

Phase 0 itself is sliced into four shippable sub-steps; each is independently
mergeable and leaves `main` green.

### Phase 0.0 — Spike: validate `NLContextualEmbedding` on Korean (½ day, throwaway)

**Goal:** de-risk the one uncertain fact before building infrastructure.

- Throwaway harness (a test or a scratch CLI) that loads the CJK contextual model,
  embeds a few **Korean** fixture notes + queries, mean-pools to a doc vector, and
  prints cosine similarities.
- **Decision gate:** confirm (a) assets load on this machine, (b) runtime
  `dimension` (expect 512), (c) cosine *separates* a related Korean note from an
  unrelated one by a usable margin. If Korean quality is poor → escalate to the
  Core ML MiniLM backend **but keep all the Phase 0.1 interfaces identical** (only
  the `EmbeddingProvider` impl changes).
- Delete the spike before merging.

**Gate result (2026-06-06 — PASSED).** `NLContextualEmbedding(language: .korean)` loads
at the `arm64e-apple-macos14.0` floor in ~0.4 s. Runtime `dimension = 512` (matches
assumption). `hasAvailableAssets = true` on the dev machine (on-demand `requestAssets`
path coded as fallback). Mean-pooled cosine on Korean fixtures: related 회의/일정 pair
= **0.845**, unrelated 요리 note = 0.586 / 0.596 → **separation margin +0.249**, a
comfortable usable gap. No escalation to Core ML MiniLM needed; proceed on the
`NLContextualEmbedding` spine. (Spike harness:
`Tests/HTMLGraphCoreTests/SpikeNLContextualEmbeddingTests.swift`, removed after 0.1.)

### Phase 0.1 — Core substrate, no UI, no app wiring (shippable, inert) ✅ DONE (2026-06-06)

**Status:** Implemented on branch `feat/semantic-search`. All five files shipped under
`Sources/HTMLGraphCore/Embedding/` (`EmbeddingProvider`, `EmbeddingMath`, `EmbeddingInput`,
`VaultEmbeddingStore`, `SemanticIndexer`) plus `HTMLMetadataExtractor.bodyText`. Test
suites added under `Tests/HTMLGraphCoreTests/Embedding/` (math, store round-trip/mismatch,
input chunking, indexer skip/recompute/ghost-prune/full≡incremental, ranking fusion) —
**183 tests pass** (`swift test`) and **`xcodebuild` BUILD SUCCEEDED** (pbxproj registered:
new `Embedding` group + 5 file/build refs). Notes on what firmed up during impl: types are
`Sendable` for the 0.2 detached-Task hooks (`VaultEmbeddingStore` dropped its stored
`FileManager`); `SemanticIndexer` takes an injectable `bodyTextLoader` (default reads
disk + SwiftSoup) so unit tests don't need fixtures; added `embedRecord(for:)` for the 0.2
single-doc incremental hook.

**Goal:** all of semantic search as **pure, unit-tested `HTMLGraphCore` types**,
exercised only by a deterministic fake provider. Nothing touches `AppState` or the
UI yet — fully inert.

New files (`Sources/HTMLGraphCore/Embedding/`):

| File | Responsibility |
|---|---|
| `EmbeddingProvider.swift` | `protocol EmbeddingProvider: Sendable { var identifier: String; var dimension: Int; func embed(_ text: String) async throws -> [Float] }` + a `DeterministicEmbeddingProvider` (hash-seeded vectors) for tests |
| `VaultEmbeddingStore.swift` | Sidecar persistence mirroring `VaultIndexExporter`. Envelope `{ schemaVersion, providerId, dimension, entries: [docId: {contentHash, vector}] }`; vector stored as **base64 little-endian Float32** (compact + exact). `providerId`/`dimension`/`schemaVersion` mismatch on load ⇒ discard all (forces rebuild when the backend changes). Writes atomically to `<vault>/.htmlgraph/embeddings.json` via `VaultIndexExporter.sidecarDirectory(forVault:)`. |
| `EmbeddingMath.swift` | `cosineSimilarity`, L2-normalize, mean-pool — pure, trivially tested. |
| `SemanticIndexer.swift` | Orchestrates refresh + search. `refresh(index:store:provider:vaultURL:) async -> EmbeddingIndex` re-embeds only docs whose `(id,hash)` changed, **prunes entries for docIds no longer in `index.documents`** (ghost-node defense), returns the updated in-memory index. `search(query:in:graph:topK:) async -> [ScoredHit]` embeds the query, cosine-ranks, then applies the centrality re-rank. |
| `EmbeddingInput.swift` | Builds the text fed to the model: `title + "\n" + bodyText` (capped), chunked to ~256 tokens with chunk-vector mean-pooling for long docs. |

Extend existing (additive, schema-safe):

- `HTMLMetadataExtractor.swift` — add
  `func bodyText(from html: String, maxChars: Int = 4000) throws -> String` using
  SwiftSoup `document.body()?.text()` (strips tags/scripts/styles, collapses
  whitespace, empty/implicit body ⇒ `""`). Mirrors the existing `title(from:)` /
  `links(from:)` shape; no signature changes to current methods.

**Centrality re-rank (graph fusion).** Compute degree directly from
`VaultIndex.edges` (resolved edges only — both out-degree from `sourceId` and
in-degree from `targetId`); semantics dominate and centrality only breaks near-ties:

```
finalScore = cosine + β · ( log(1 + degree) / log(1 + maxDegree) )   // β ≈ 0.08, tunable
```

Tests (`Tests/HTMLGraphCoreTests/Embedding/`), all with the deterministic provider:

- `EmbeddingMathTests` — identical⇒1.0, orthogonal⇒0.0, known triples⇒known order.
- `VaultEmbeddingStoreTests` — base64 float round-trip fidelity; `providerId`/`dimension`/`schemaVersion` mismatch ⇒ rebuild; atomic write.
- `SemanticIndexerTests` — unchanged `contentHash` is **skipped** (no re-embed);
  changed hash recomputes; **ghost prune** when a doc leaves the index;
  **full-refresh ≡ incremental-refresh** for the same on-disk state (the
  `IncrementalReindexTests` equivalence discipline, applied to embeddings).
- `EmbeddingInputTests` / `HTMLMetadataExtractorTests` — body-text extraction,
  `maxChars` cap, implicit/empty body ⇒ `""`, script/style stripped.
- `SemanticRankingTests` — cosine + centrality fusion produces the expected order on a fixture graph.

### Phase 0.2 — Real provider + index lifecycle wiring (background, gen-guarded; still no visible UI) ✅ DONE (2026-06-06)

**Status:** Implemented on `feat/semantic-search`. `NLContextualEmbeddingProvider`
(actor, CJK `.korean` model, lazy `hasAvailableAssets`→`requestAssets`→`load`, per-token
mean-pool, `identifier = "nl-contextual.cjk.v1"`) + `EmbeddingProviderError.assetsUnavailable`.
AppState: `embeddingProvider`/`embeddingStore`/`@Published embeddingIndex`/
`@Published semanticIndexState`/`embeddingGeneration` state; `SemanticIndexState` enum;
full re-embed hook in `finishIndexing` (after the graph.json export) and incremental
re-embed in `writeEditorText` (after the sync `reindexDocument`+export — reindex stays
synchronous per issue #6); `beginSession` resets embedding state + bumps generation on
vault switch; all background work is `Task.detached(.utility)` with a MainActor publish
and generation guard. Korean correctness integration test added (guardrail #7, skips when
assets absent) — **185 tests pass**, **xcodebuild BUILD SUCCEEDED**. Deviations from plan:
the provider exposes `assetsAreAvailable`/`prepare()` (concrete-type extras, not on the
protocol) for a future `.preparingAssets` surface; 0.2 currently goes `building → ready/
unavailable` (no `.preparingAssets` transition yet — assets were already present, so wiring
it is deferred to 0.3 where the state is actually shown).

**Goal:** the live embedding index stays current as the vault is indexed and edited,
using the **real** `NLContextualEmbedding` provider — but with no user-facing search
yet (verify via tests / a temporary debug menu item).

New file:

- `Sources/HTMLGraphCore/Embedding/NLContextualEmbeddingProvider.swift` —
  `EmbeddingProvider` over `NLContextualEmbedding` (CJK script model). Handles
  `hasAvailableAssets` → `requestAssets` → `load()`, mean-pools per-token output,
  exposes runtime `dimension`. `identifier = "nl-contextual.cjk.v1"`.

AppState wiring (`Sources/HTMLGraph/AppState.swift`) — new `@MainActor` state +
two hooks that **piggyback the existing index lifecycle**:

- New state: `private var embeddingIndex: EmbeddingIndex?`, an
  `EmbeddingProvider` instance, `private var embeddingGeneration = UUID()`, and a
  `@Published var semanticIndexState` (`.idle/.preparingAssets/.building(progress)/.ready/.unavailable`).
- **Full re-embed hook** — in `finishIndexing(...)` success branch, *after* the
  existing `VaultIndexExporter().export(builtIndex, …)` (`AppState.swift:591`): fire
  a detached, generation-guarded `Task` that calls `SemanticIndexer.refresh(...)`
  and, on completion, hops to `@MainActor` to publish `embeddingIndex`. Guard with a
  captured `embeddingGeneration`; a superseded vault open drops its result. **Does
  not block indexing** (best-effort, exactly like the `graph.json` export).
- **Incremental re-embed hook** — in `writeEditorText(...)`, *after* `self.index =
  patched` + the sidecar export (`AppState.swift:1105-1111`): fire-and-forget
  `Task { await self.refreshEmbedding(documentId: documentId) }`. This re-embeds
  exactly one doc and patches `embeddingIndex`.
  **⚠️ The async embedding is layered *after* the synchronous `reindexDocument`
  returns — `reindexDocument` itself is NOT wrapped in a Task** (issue #6: that
  would break the sync `Bool` return, the `indexingGeneration` race guard, and the
  atomic write+patch). Embedding never gates save success.

Asset/availability handling: first time semantic search is needed, if
`hasAvailableAssets == false`, set `.preparingAssets`, `requestAssets`, then build.
If assets can't be obtained (or the model is unavailable for the content), set
`.unavailable` → the UI silently keeps lexical mode (see 0.3).

### Phase 0.3 — Search-mode toggle + semantic results in the sidebar (the user-visible ship)

**Goal:** the feature becomes usable, in the **minimal/native** style the project
demands (the in-app-editor memo: *no AI slop* — no colored pills, no status bars;
quiet, understated, macOS-conventional).

- New state: `@Published var searchMode: SearchMode = .title` (`enum { title, meaning }`),
  `@Published private(set) var semanticResults: [DocumentNode] = []`, and a
  `searchGeneration` token. `func runSemanticSearch()` debounces, embeds the query
  on a background `Task` (gen-guarded so a stale query's results are dropped),
  ranks via `SemanticIndexer.search`, maps hit ids → `DocumentNode`, publishes.
- **Mode toggle** placed by the existing search field: `ContentView.swift:12` hosts
  `.searchable(text: $appState.searchText, placement: .sidebar, …)`. Add a small,
  unobtrusive `Picker`/segmented control ("Title" | "Meaning") in the sidebar
  toolbar or just under the field.
- **Results branch** in `VaultSidebar.documentsSection` (`VaultSidebar.swift:52-70`):
  when `searchMode == .meaning && isSearching`, render `appState.semanticResults`
  instead of `appState.filteredDocuments`; reuse `SidebarRowLabel` and the existing
  `documentContextMenu`. Show a single quiet "Searching…" row while embedding, an
  empty state when no hits, and — when `semanticIndexState == .unavailable` —
  transparently fall back to lexical with a one-line note. `.title` mode is
  unchanged (`filteredDocuments`).

No changes to graph rendering, the editor, the HTTP server, or any write path.

---

## Exact wiring points (file:line)

| Seam | Location | Change |
|---|---|---|
| Full re-embed | `AppState.finishIndexing`, after `VaultIndexExporter().export` | `AppState.swift:591` |
| Incremental re-embed | `AppState.writeEditorText`, after `self.index = patched` + export | `AppState.swift:1105–1111` |
| Body text for embedding | `HTMLMetadataExtractor` (new method) | `HTMLMetadataExtractor.swift` |
| Sidecar directory | `VaultIndexExporter.sidecarDirectory(forVault:)` (reuse) | `VaultIndexExporter.swift:88` |
| Lexical search (leave intact) | `AppState.filteredDocuments` | `AppState.swift:355–364` |
| Search field host / mode toggle | `.searchable(...)` | `ContentView.swift:12` |
| Results branch | `VaultSidebar.documentsSection` | `VaultSidebar.swift:52–70` |
| Degree for re-rank | computed from `VaultIndex.edges` (resolved) | `VaultIndex.swift` |

## Guardrails / constraints (do not regress)

1. **Don't touch `graph.json`.** Embeddings live in a **separate** hidden sidecar.
   The `schemaVersion=1` `ExportedGraph` contract and
   `VaultIndexExporterTests.testExportedKeysCoverAllVaultIndexFields` stay green.
2. **Don't wrap `reindexDocument` in a Task** (issue #6). Only the *embedding* is
   async, and only *after* the synchronous reindex returns. Save success never
   depends on embedding.
3. **Ghost-node pruning.** On full refresh, drop store entries whose docId is no
   longer in `index.documents`, or semantic search surfaces deleted "ghost" notes.
4. **`contentHash` gate is load-bearing for cost.** Without it, every `openVault`
   re-embeds the whole vault (~50 s / 1000 chunks on M1). With it, steady-state cost
   tracks edits-per-session; the full build is one-time and persisted.
5. **Stale-result generation guards** on *both* the background re-embed
   (`embeddingGeneration`) and the query embed (`searchGeneration`) — a superseded
   vault-open or an outdated keystroke must not publish.
6. **Graceful fallback.** If `NLContextualEmbedding` assets are unavailable, set
   `.unavailable` and keep lexical search working — never block the sidebar.
7. **Korean correctness test.** An integration test asserts the real provider
   returns a non-nil, finite 512-d vector for Korean input (skipped in CI when
   assets aren't present), guarding the `NLEmbedding`-returns-nil trap.
8. **Stays in Safe mode, zero egress.** No `WKWebView`, no network, no new
   entitlement. `embeddings.json` holds derived vectors only (same local-artifact
   exposure class as the existing `graph.json`).
9. **Xcode project registration.** Every new `.swift` file needs a
   `project.pbxproj` entry or `xcodebuild` fails even though SwiftPM auto-discovers
   it — verify with **both** `swift test` and `xcodebuild`. See
   [[xcodeproj-new-file-registration]].

## Verification

```bash
swift build && swift test                      # SPM: all Core + app tests
xcodebuild -scheme HTMLGraph -destination 'platform=macOS' build   # pbxproj parity
swift run HTMLGraph                            # manual: open Fixtures/sample-vault, toggle Meaning, query
```

Manual QA: open a vault, switch the toggle to **Meaning**, type a meaning-based
(Korean) query, confirm semantically-related notes rank above lexically-distinct
ones; edit a note + ⌘S, confirm its semantic match updates without a full reindex
(selection/scroll preserved); delete a note, confirm it stops appearing in semantic
results (ghost prune).

## Out of scope for Phase 0 (later phases)

MCP server/tools · in-app copilot/RAG answers · remote (Claude) models · AI-suggested
`<a href>` edges · agent-activity Inbox · auto-title/summary/tags · per-chunk
retrieval & citations · embedding Inbox items. Phase 0 ships *only* the on-device
semantic search index + UI toggle, as the substrate the rest build on.
