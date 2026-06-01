# HTMLGraph Design

Date: 2026-06-01
Status: Draft approved for implementation planning

## Summary

HTMLGraph is a macOS-first desktop viewer for local HTML knowledge vaults. It takes Obsidian's local-first graph and backlink model as the product reference, but uses HTML files instead of Markdown. The first version is a viewer, not an editor: users open a local folder of HTML files, read documents, follow local links, inspect backlinks, and explore local or global graph views.

The selected architecture is a native SwiftUI macOS shell with a WKWebView-based renderer. SwiftUI owns the Mac app surface, permissions, vault selection, app cache, file watching, external editor integration, and Safe/Trusted vault mode. The web renderer owns HTML document rendering and graph visualization.

## Goals

- Open a local folder as a vault of HTML documents.
- Render HTML documents in a document-first interface.
- Build graph edges from standard `<a href>` links between local HTML files.
- Compute backlinks automatically from incoming link edges.
- Show a three-pane workspace: vault/search, reader, and context panel.
- Default to local graph around the active document, with global graph available separately.
- Keep the source vault read-only; store indexes and settings in the app cache.
- Provide a safe default execution mode and a vault-scoped trusted mode.
- Support opening the current HTML file in an external editor.

## Non-Goals

- Editing HTML inside HTMLGraph.
- Writing sidecar files into the vault.
- Crawling remote websites.
- Parsing tags, metadata, or `[[wiki-link]]` syntax in the MVP.
- Plugin or theme APIs in the MVP.
- Windows/Linux support in the MVP.

Tags, metadata-derived edges, and wiki-link parsing are deliberate extensions after the link/backlink core is stable.

## Reference Model

Obsidian's graph view separates global graph from local graph. Global graph shows the vault-wide note network, while local graph shows notes connected to the active note and supports depth control. HTMLGraph follows that split: the right context panel shows local graph by default, and global graph opens as a separate workspace.

Obsidian's backlink model is active-document centered: a backlink is an incoming link from another note to the current note. HTMLGraph starts with linked backlinks only. Unlinked mention detection is not part of the MVP because HTML file naming, headings, and visible text do not provide a reliable canonical note name yet.

Zettlr's graph documentation includes an important product constraint: visual graph position is not semantic. HTMLGraph should avoid making the graph the main source of meaning. The user value is reading a document, seeing incoming and outgoing relationships, and navigating those relationships.

Sources:
- Obsidian Graph View: https://obsidian.md/help/plugins/graph
- Obsidian Backlinks: https://obsidian.md/help/plugins/backlinks
- Zettlr Graph View: https://docs.zettlr.com/en/advanced/graph/
- Logseq: https://logseq.com/

## Architecture

HTMLGraph uses three main boundaries.

### Vault Indexer

The indexer scans a selected local folder and builds a graph model from HTML files.

Responsibilities:
- Discover `.html` and `.htm` files under the vault root.
- Parse document title from `<title>`, then first `<h1>`, then filename.
- Extract `<a href>` links.
- Normalize local links against the source document path.
- Classify links as internal document links, same-document fragments, external URLs, or unresolved internal links.
- Build forward edges and backlink indexes.
- Persist index cache under the app data directory.
- Watch file changes and update affected documents incrementally.

### App Shell

The SwiftUI shell owns OS integration and app state.

Responsibilities:
- Open a folder as a vault.
- Persist vault settings in app storage.
- Store index cache outside the source vault.
- Display the three-pane workspace.
- Manage Safe/Trusted vault mode.
- Provide menu commands and keyboard shortcuts.
- Open the current document in the system default app for HTML files.
- Route internal document navigation from the web renderer back into app state.

### Web Renderer

The renderer runs in WKWebView and displays the active document and graph views.

Responsibilities:
- Render the selected HTML document.
- Intercept local link clicks and ask the app shell to navigate.
- Let external links open in the system browser.
- Render local graph and global graph from the graph model.
- Display backlink and unresolved-link context.

## UI

The MVP uses a three-pane workspace.

### Left Pane: Vault Navigation

The left pane contains:
- File tree rooted at the selected vault.
- Filename/path search.
- Recent documents.

Advanced filtering, tag browsing, and metadata search are deferred.

### Center Pane: HTML Reader

The center pane is the primary surface.

It shows:
- Current document title.
- Vault-relative path.
- Safe/Trusted state.
- External editor button.
- Rendered HTML document.

Internal local HTML links navigate inside HTMLGraph. External links open in the default browser. The reader should preserve the document's own content and styling as much as the security mode allows.

### Right Pane: Context Panel

The right pane starts with two tabs:
- Backlinks: documents that link to the active document.
- Local Graph: active document, outgoing links, backlinks, and depth-limited neighbors.

Local graph starts at depth 1. Depth 2 can be enabled from the panel. Global graph opens as a separate full-window workspace, not a modal and not squeezed into the right pane.

### Keyboard Shortcuts

- `Cmd+O`: open vault.
- `Cmd+P`: quick document search.
- `Cmd+E`: open current document in external editor.
- `Cmd+G`: open global graph.

## Data Model

### DocumentNode

- `id`: stable vault-relative path identifier.
- `path`: vault-relative file path.
- `absolutePath`: local file path, app-internal only.
- `title`: extracted title.
- `contentHash`: hash used for cache invalidation.
- `lastModified`: file modified timestamp.

### LinkEdge

- `sourceId`: source document id.
- `targetId`: target document id if resolved.
- `href`: original href string.
- `normalizedTargetPath`: normalized target path if local.
- `fragment`: optional anchor fragment.
- `linkText`: visible link text.
- `status`: resolved, unresolved, same-document, or external.

### BacklinkIndex

Maps target document id to incoming `LinkEdge` entries.

### VaultIndex

- `vaultId`: app-generated vault identifier.
- `documents`: all indexed nodes.
- `edges`: all link edges.
- `backlinks`: computed incoming edge map.
- `unresolvedLinks`: unresolved internal links by source.
- `lastIndexedAt`: timestamp.

## Link Rules

- Internal graph edges are created only for links that resolve to HTML files inside the vault.
- External URLs are shown in the reader but excluded from graph edges.
- Same-document fragments are treated as in-document navigation, not graph edges.
- Cross-document fragments are stored as target document plus fragment.
- Broken local links are shown as unresolved links in the context panel.
- Query strings are preserved for navigation but do not create separate graph nodes in the MVP.

## Caching

The app stores index cache in the macOS app data directory. The vault itself remains untouched. A vault id is derived from the selected folder path plus an app-generated salt to avoid collisions and allow future migration if a folder moves.

On vault open:
1. Load existing cache if available.
2. Compare file modified times and hashes.
3. Reindex changed, added, or deleted files.
4. Rebuild affected backlink and graph indexes.

## Security

Safe Mode is the default for every vault.

Safe Mode behavior:
- Do not expose arbitrary `file://` access to WKWebView.
- Serve vault resources through an app-controlled custom URL scheme. Use a local server only if WKWebView limitations force it.
- Allow static resources from inside the vault.
- Block external network requests by default.
- Open external links in the system browser.
- Prevent HTML documents from reading files outside the vault.

Trusted Mode is vault-scoped and opt-in.

Trusted Mode behavior:
- Allows richer JavaScript execution for the trusted vault.
- Keeps network access as a separate explicit toggle.
- Displays trust state clearly in the UI.
- Does not grant permission globally across all vaults.

The SwiftUI shell owns the trust decision and the resource policy. The web renderer should not decide what the document is allowed to load.

## Testing

### Fixtures

The repo should include a sample HTML vault with at least:
- Six HTML documents.
- Bidirectional links.
- A one-way backlink case.
- A cycle.
- An orphan document.
- A broken local link.
- A same-document fragment link.
- A cross-document fragment link.
- CSS and image resources.

### Unit Tests

Indexer tests:
- Title extraction priority.
- Href normalization.
- Internal vs external link classification.
- Backlink generation.
- Broken link detection.
- Fragment handling.

Policy tests:
- External request blocking in Safe Mode.
- Vault-outside file access blocking.
- Trusted Mode enabling JavaScript for a selected vault.
- Network access remaining separate from Trusted Mode.

### App Flow Tests

- Open sample vault.
- Render a document.
- Click an internal HTML link and navigate inside the app.
- Show backlinks for the active document.
- Show local graph for the active document.
- Open global graph.
- Show unresolved links.
- Trigger external editor action.
- Relaunch app and reuse cache.

## MVP Acceptance Criteria

- A user can open a local HTML folder as a vault in the macOS app.
- The app indexes HTML files and extracts document titles.
- The center pane renders selected HTML documents.
- Local HTML links navigate inside the app.
- The context panel shows linked backlinks for the active document.
- The context panel shows a depth-1 local graph.
- A separate global graph view is available.
- Broken internal links appear as unresolved links.
- The current document can be opened in an external editor.
- The app reuses cached indexes after relaunch.
- Safe Mode is the default.
- Trusted Mode can be enabled per vault.

## Open Extensions

These are intentionally outside the MVP but should not be blocked by the architecture:
- Tags and metadata from `<meta>`, `data-tags`, or class conventions.
- `[[wiki-link]]` parsing inside HTML text.
- Unlinked mention detection.
- Sidecar export for teams that want graph state in git.
- Web import or website crawl mode.
- Plugin API.
- Windows/Linux support.

## Implementation Planning Notes

The implementation plan should start with a minimal vertical slice:
1. SwiftUI app shell opens a vault folder.
2. Indexer scans sample HTML files and builds graph JSON.
3. WKWebView renders one selected document through a controlled resource loader.
4. Backlinks list appears for the active document.
5. Local graph renders depth 1.

This slice proves the core product before adding global graph polish, file watching, cache invalidation, and trusted-mode UI.
