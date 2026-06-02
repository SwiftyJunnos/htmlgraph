# HTMLGraph

HTMLGraph is a macOS-first desktop viewer for local HTML knowledge vaults.

## MVP

- Open a local folder of `.html` / `.htm` files.
- Read HTML documents in a three-pane workspace.
- Build graph edges from local `<a href>` links.
- Show backlinks for the active document.
- Show local and global graph views.
- Keep the source vault read-only.

## AI Inbox

External AI tools can hand new knowledge to HTMLGraph by writing `.html` or `.htm`
files under an `Inbox/` folder at the vault root:

```text
MyVault/
  Inbox/
    generated-note.html
```

Inbox documents are previewed separately and are not included in the main graph
until accepted. Accepting an inbox item asks for a destination path inside the
vault, moves the file there, and reindexes the vault. HTMLGraph refuses to accept
items outside `Inbox/`, overwrite existing files, write outside the vault, or
save accepted items back into `Inbox/`.

## Development

```bash
swift test
swift run HTMLGraph
```

## TestFlight

HTMLGraph includes an Xcode project for macOS TestFlight distribution. See `docs/testflight.md` for signing, archive, and upload steps.

## Manual QA Fixture

Open `Fixtures/sample-vault` from the app.

Expected:
- `HTMLGraph Home` appears in the reader.
- Clicking `Graph note` navigates inside the app.
- `Graph View` shows a backlink from `index.html`.
- `Orphan` has no backlinks.
- `Broken local link` appears under unresolved links.
