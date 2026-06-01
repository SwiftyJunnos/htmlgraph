# HTMLGraph

HTMLGraph is a macOS-first desktop viewer for local HTML knowledge vaults.

## MVP

- Open a local folder of `.html` / `.htm` files.
- Read HTML documents in a three-pane workspace.
- Build graph edges from local `<a href>` links.
- Show backlinks for the active document.
- Show local and global graph views.
- Keep the source vault read-only.

## Development

```bash
swift test
swift run HTMLGraph
```

## Manual QA Fixture

Open `Fixtures/sample-vault` from the app.

Expected:
- `HTMLGraph Home` appears in the reader.
- Clicking `Graph note` navigates inside the app.
- `Graph View` shows a backlink from `index.html`.
- `Orphan` has no backlinks.
- `Broken local link` appears under unresolved links.
