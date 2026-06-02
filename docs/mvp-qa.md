# HTMLGraph MVP QA

Use `Fixtures/sample-vault`.

- [ ] App opens on macOS with `swift run HTMLGraph`.
- [ ] `Open Vault` accepts `Fixtures/sample-vault`.
- [ ] Sidebar lists six HTML documents.
- [ ] Selecting `HTMLGraph Home` renders the HTML document.
- [ ] Local HTML link clicks navigate inside the app.
- [ ] External links open in the default browser.
- [ ] Backlinks tab updates when the active document changes.
- [ ] Unresolved tab shows `./notes/missing.html` for `HTMLGraph Home`.
- [ ] Local graph shows active document and linked neighbors.
- [ ] `Cmd+G` opens the global graph window.
- [ ] Safe mode is selected by default.
- [ ] Trusted mode can be selected per vault.
- [ ] Source vault remains unchanged after browsing.
- [ ] Creating `Inbox/generated-note.html` while the vault is open shows it in the Inbox section.
- [ ] Selecting an Inbox item previews it without adding it to the main document list.
- [ ] Accepting an Inbox item moves it to the chosen vault path and reindexes it into the main document list.
- [ ] `swift test` passes.
