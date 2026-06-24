import HTMLGraphCore
import SwiftUI

/// Stable identity for a rendered document/inbox web view, used as the SwiftUI `.id()`.
///
/// Embedding `trustMode` and `allowsNetworkAccess` here is load-bearing security, not
/// cosmetic: `HTMLDocumentWebView` applies the security policy — the JavaScript gate
/// (`allowsContentJavaScript`) and the network-blocking `WKContentRuleList` — only when
/// the web view is built (`makeNSView`), never in `updateNSView`. A policy change can
/// therefore only take effect by discarding and rebuilding the web view, which SwiftUI
/// does precisely when this identity string changes. Drop trust/network from the identity
/// and a Safe→Trusted (or network) toggle would silently fail to apply to the live view.
/// `WebResourcePolicyTests` guards this invariant.
enum WebViewIdentity {
    static func make(
        vaultPath: String,
        contentId: String,
        contentHash: String? = nil,
        trustMode: VaultTrustMode,
        allowsNetworkAccess: Bool
    ) -> String {
        var parts = [vaultPath, contentId]
        if let contentHash {
            parts.append(contentHash)
        }
        parts.append(trustMode.rawValue)
        parts.append(String(allowsNetworkAccess))
        return parts.joined(separator: "|")
    }
}

/// How the document pane is presenting the current document.
enum EditorMode {
    /// Rendered, read-only preview.
    case read
    /// Rendered preview made editable in place (WYSIWYG) — edit the content, not the markup.
    case visual
    /// The raw HTML source in a plain-text editor, for precise markup edits.
    case source

    var isEditing: Bool { self != .read }
}

struct ReaderPane: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("preferredEditorBundleID") private var preferredEditorBundleID = ""
    let onChooseVault: () -> Void
    let onAcceptInboxItem: (InboxItem) -> Void

    /// Read vs Edit for the current document. View-local because it's a presentation
    /// concern; the actual edit buffer lives in `AppState` so it survives view rebuilds.
    @State private var editorMode: EditorMode = .read
    /// Guards against re-entrancy when we programmatically revert a selection change the
    /// user cancelled out of (reverting re-fires `onChange`).
    @State private var isRevertingSelection = false
    /// Lets the host pull the WYSIWYG editor's live DOM before a save or before leaving, so a
    /// synchronous save never writes a stale (debounced) buffer. One per pane; the active
    /// visual editor registers itself.
    @State private var visualBridge = VisualEditorBridge()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.isIndexing {
                ProgressView("Indexing vault...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let item = appState.selectedInboxItem {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text("Unfiled · not in your graph yet — add it to include it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Menu("Add to Vault") {
                        Button("Vault Root") {
                            SidebarActions.addToVault(item, folder: nil, appState: appState)
                        }
                        if !appState.vaultFolders.isEmpty {
                            Divider()
                            ForEach(appState.vaultFolders, id: \.self) { folder in
                                Button(folder) {
                                    SidebarActions.addToVault(item, folder: folder, appState: appState)
                                }
                            }
                        }
                        Divider()
                        Button("Choose Folder…") {
                            onAcceptInboxItem(item)
                        }
                    } primaryAction: {
                        SidebarActions.addToVault(item, folder: nil, appState: appState)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .help("Add this item to your vault so it joins the graph. Click for the vault root, or use the menu to pick a folder.")

                    openInEditorButton(absolutePath: item.absolutePath)
                }
                .padding()

                Divider()

                if let vaultURL = appState.vaultURL {
                    if let baseURL = appState.vaultBaseURL {
                        documentWebView(
                            documentURL: URL(fileURLWithPath: item.absolutePath),
                            identity: inboxWebViewIdentity(for: item, vaultURL: vaultURL),
                            vaultURL: vaultURL,
                            baseURL: baseURL
                        )
                    } else {
                        preparingPreview
                    }
                } else {
                    ContentUnavailableView(
                        "No vault selected",
                        systemImage: "folder",
                        description: Text("Choose a local HTML folder to preview this inbox item.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let document = appState.selectedDocument {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(document.title)
                                .font(.headline)
                                .lineLimit(1)
                            // The macOS document convention for unsaved changes — a quiet
                            // "Edited" beside the title, rather than a colored badge.
                            if editorMode.isEditing, appState.hasUnsavedEdits {
                                Text("Edited")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(document.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if editorMode.isEditing {
                        Button("Save") {
                            Task {
                                if editorMode == .visual { await visualBridge.flush() }
                                await appState.saveEditorBuffer()
                            }
                        }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!appState.hasUnsavedEdits)
                        .help("Save changes to this document (⌘S).")
                    }
                    modeButton(for: document)
                    externalActionsMenu(for: document)
                }
                .padding()

                Divider()

                documentContent(for: document)
            } else {
                if appState.vaultURL == nil {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "Open a vault",
                            systemImage: "folder",
                            description: Text("Choose a local HTML folder to begin.")
                        )

                        Button {
                            onChooseVault()
                        } label: {
                            Label("Open Vault", systemImage: appState.openVaultSymbolName)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityLabel("Open Vault")
                        .help("Choose a local HTML folder to open as a vault.")

                        if !appState.recentVaults.isEmpty {
                            recentVaultsList
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No HTML documents",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("This vault has no indexed HTML files.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // A floating overlay rather than a VStack sibling: toggling a bar in the root
        // layout at runtime perturbs the NavigationSplitView unified toolbar (the
        // window titlebar collapses). An overlay never reflows the column or the toolbar.
        .overlay(alignment: .bottom) {
            if appState.networkBlockedNotice {
                networkBlockedBanner
            }
        }
        // Leaving the document we're editing must not silently drop unsaved text.
        .onChange(of: appState.sidebarSelection) { oldValue, newValue in
            handleSelectionChange(from: oldValue, to: newValue)
        }
        .alert(
            "Document changed on disk",
            isPresented: Binding(
                get: { appState.editorConflict != nil },
                set: { if !$0 { appState.dismissConflict() } }
            )
        ) {
            Button("Overwrite", role: .destructive) { Task { await appState.resolveConflictByOverwriting() } }
            Button("Reload") { appState.resolveConflictByReloading() }
            Button("Cancel", role: .cancel) { appState.dismissConflict() }
        } message: {
            Text("“\(appState.editorConflict?.documentId ?? "")” was modified by another program since you started editing. Overwrite it with your changes, or reload the version on disk — reloading discards your unsaved edits.")
        }
    }

    // MARK: - Editor mode

    /// The in-app mode toggle: a single button labelled by its ACTION (never the current
    /// state), so it always says what a click does — "Edit" while reading, "Done" while
    /// editing. The primary action enters *visual* (WYSIWYG) editing — editing the rendered
    /// content directly is the common case; the raw-HTML source surface lives one click away
    /// in the actions menu. State legibility is carried by the environment (header wash,
    /// accent rule, status bar), not this button, so it stays calm and bordered. ⌘↩ toggles.
    private func modeButton(for document: DocumentNode) -> some View {
        Button {
            Task { await togglePrimaryEdit(for: document) }
        } label: {
            if editorMode.isEditing {
                Label("Done", systemImage: "checkmark")
            } else {
                Label("Edit", systemImage: "pencil")
            }
        }
        .buttonStyle(.bordered)
        // ⌘↩ ("commit") rather than ⌘E — ⌘E is the system "Use Selection for Find" action
        // inside the source NSTextView, and shadowing it while editing would surprise users.
        .keyboardShortcut(.return, modifiers: .command)
        .help(editorMode.isEditing
            ? "Finish editing and return to the rendered view (⌘↩)."
            : "Edit this document’s content in place (⌘↩).")
    }

    /// Secondary actions, kept as a separate momentary-action menu so they never hide behind
    /// the stateful mode toggle. Houses the choice of in-app edit surface — visual (the
    /// primary button's default) vs. raw HTML source for precise markup edits — plus the
    /// heavier "edit in a real editor" / Finder paths. Visible in every mode.
    private func externalActionsMenu(for document: DocumentNode) -> some View {
        let editors = ExternalEditor.installedEditors()
        let absolutePath = document.absolutePath
        return Menu {
            Section("Edit In-App") {
                Button {
                    Task { await setMode(.visual, for: document) }
                } label: {
                    Label("Edit Content (Visual)", systemImage: editorMode == .visual ? "checkmark" : "pencil")
                }
                Button {
                    Task { await setMode(.source, for: document) }
                } label: {
                    Label("Edit HTML Source", systemImage: editorMode == .source ? "checkmark" : "chevron.left.forwardslash.chevron.right")
                }
            }
            if !editors.isEmpty {
                Section("Open Source In…") {
                    ForEach(editors) { editor in
                        Button("Open in \(editor.name)") {
                            openSourceExternally(editor, absolutePath: absolutePath)
                        }
                    }
                }
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the in-app edit surface, open the HTML source in an external editor, or reveal it in Finder.")
        .accessibilityLabel("Document actions")
    }

    /// The primary mode button: read → visual (the common case), and any edit mode → read.
    private func togglePrimaryEdit(for document: DocumentNode) async {
        await setMode(editorMode == .read ? .visual : .read, for: document)
    }

    /// Switches the document pane between read / visual / source. Every transition that
    /// leaves or swaps an edit surface routes through the unsaved-edits guard first, so no
    /// path can silently drop unsaved text; a clean buffer makes the guard a no-op. Leaving
    /// the visual editor first flushes its live DOM into the buffer (the web view is still
    /// alive here, since WE trigger its teardown by changing the mode), so the guard's save
    /// reflects the latest keystrokes rather than the last debounce.
    private func setMode(_ target: EditorMode, for document: DocumentNode) async {
        guard editorMode != target else { return }
        if editorMode == .visual {
            await visualBridge.flush()
        }
        if editorMode.isEditing, appState.hasUnsavedEdits, !(await EditorGuard.confirmLeavingEditor(appState)) {
            // Cancelled, or a conflict that must be resolved first — stay put.
            return
        }
        switch target {
        case .read:
            appState.endEditing()
            editorMode = .read
        case .visual, .source:
            // Re-baseline from disk when entering (or swapping into) an edit surface so it
            // loads the just-saved / just-discarded bytes rather than a stale buffer.
            appState.endEditing()
            if await appState.beginEditing(document) {
                if target == .visual { appState.beginVisualSession() }
                editorMode = target
            } else {
                editorMode = .read
            }
        }
    }

    @ViewBuilder
    private func documentContent(for document: DocumentNode) -> some View {
        switch editorMode {
        case .source:
            DocumentSourceEditor(
                text: Binding(
                    get: { appState.editorBuffer?.currentText ?? "" },
                    set: { appState.updateEditorText($0) }
                ),
                isEditable: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .visual:
            if let vaultURL = appState.vaultURL {
                if let baseURL = appState.vaultBaseURL {
                    VisualHTMLEditor(
                        documentId: document.id,
                        documentURL: URL(fileURLWithPath: document.absolutePath),
                        vaultURL: vaultURL,
                        baseURL: baseURL,
                        allowsNetworkAccess: appState.allowsNetworkAccess,
                        bridge: visualBridge,
                        onSnapshot: { documentId, body, full in
                            appState.updateVisualEditedDocument(
                                documentId: documentId, bodyInnerHTML: body, fullHTML: full
                            )
                        },
                        onNavigationError: { appState.errorMessage = $0 }
                    )
                    .id(visualWebViewIdentity(for: document, vaultURL: vaultURL))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    preparingPreview
                }
            } else {
                noVaultPlaceholder
            }
        case .read:
            if let vaultURL = appState.vaultURL {
                if let baseURL = appState.vaultBaseURL {
                    documentWebView(
                        documentURL: URL(fileURLWithPath: document.absolutePath),
                        identity: webViewIdentity(for: document, vaultURL: vaultURL),
                        vaultURL: vaultURL,
                        baseURL: baseURL
                    )
                } else {
                    preparingPreview
                }
            } else {
                noVaultPlaceholder
            }
        }
    }

    private var noVaultPlaceholder: some View {
        ContentUnavailableView(
            "No vault selected",
            systemImage: "folder",
            description: Text("Choose a local HTML folder to render this document.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleSelectionChange(from oldValue: SidebarSelection?, to newValue: SidebarSelection?) {
        if isRevertingSelection {
            isRevertingSelection = false
            return
        }
        guard editorMode.isEditing else { return }

        if editorMode == .visual {
            // The outgoing visual editor has already been swapped out of the view by the time
            // this runs, so we can't pull its DOM directly; instead it fired a final snapshot
            // on `blur` (focus left for the sidebar). Defer the guard one runloop tick so that
            // snapshot is delivered into the buffer before we read hasUnsavedEdits — otherwise
            // the very last keystrokes could be missed. (Leading-edge dirty marking guarantees
            // an edited document is never mistaken for a clean one and silently switched.)
            DispatchQueue.main.async { resolveLeaveForSelectionChange(from: oldValue) }
        } else {
            resolveLeaveForSelectionChange(from: oldValue)
        }

        func resolveLeaveForSelectionChange(from oldValue: SidebarSelection?) {
            Task {
                if appState.hasUnsavedEdits, !(await EditorGuard.confirmLeavingEditor(appState)) {
                    // Cancelled or unresolved conflict — put the selection back where it was.
                    isRevertingSelection = true
                    appState.sidebarSelection = oldValue
                    return
                }
                appState.endEditing()
                editorMode = .read
            }
        }
    }

    private func documentWebView(documentURL: URL, identity: String, vaultURL: URL, baseURL: URL) -> some View {
        HTMLDocumentWebView(
            documentURL: documentURL,
            vaultURL: vaultURL,
            baseURL: baseURL,
            policy: appState.securityPolicy,
            knownDocumentIds: Set(appState.index?.documents.map(\.id) ?? []),
            onInternalNavigation: { appState.selectDocument($0) },
            onExternalNavigation: { url in
                if !NSWorkspace.shared.open(url) {
                    appState.errorMessage = "Could not open \(url.absoluteString) in the default external app."
                }
            },
            onNavigationError: { appState.errorMessage = $0 },
            onNetworkBlocked: { _ in
                // Defer out of the WebKit navigation callback so the state change can't
                // land inside a SwiftUI layout pass.
                DispatchQueue.main.async { appState.networkBlockedNotice = true }
            }
        )
        .id(identity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var preparingPreview: some View {
        if appState.previewServerFailed {
            ContentUnavailableView(
                "Preview unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("The local preview server could not start. Try reopening the vault.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Preparing preview…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var networkBlockedBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Network content blocked")
                    .font(.callout.weight(.semibold))
                Text("Embedded video and other remote content need network access. Allowing it also trusts this vault to run JavaScript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Button("Allow Network") {
                // Safe for a live visual edit: its web view identity no longer keys on the
                // network policy, so enabling network won't rebuild/reload it (the rules
                // refresh on the next load). The reader rebuilds correctly.
                appState.enableNetworkAccess()
            }
            .buttonStyle(.borderedProminent)
            .help("Switch this vault to Trusted mode with network access — lets documents run JavaScript and load remote content. Use only for documents you trust.")

            Button {
                appState.networkBlockedNotice = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss network notice")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        // A neutral floating card (not a full-bleed colored bar). The unified toolbar
        // is translucent, so a colored bar at the top edge would tint the whole
        // titlebar; an inset, opaque, neutral card with an orange icon accent avoids
        // that and reads cleaner.
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 2)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var recentVaultsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(Array(appState.recentVaults.prefix(5))) { recent in
                Button {
                    appState.openRecent(recent)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recent.displayName)
                                .lineLimit(1)
                            Text(recent.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Remove from Recent", role: .destructive) {
                        appState.removeRecent(recent)
                    }
                }
            }
        }
        .frame(maxWidth: 360)
    }

    private func openInEditorButton(absolutePath: String) -> some View {
        let editors = ExternalEditor.installedEditors()
        let preferred = editors.first { $0.bundleID == preferredEditorBundleID } ?? editors.first

        return Menu {
            if editors.isEmpty {
                Text("No supported editor found")
            } else {
                ForEach(editors) { editor in
                    Button(editor.name) {
                        preferredEditorBundleID = editor.bundleID
                        openWith(editor, absolutePath: absolutePath)
                    }
                }
            }
        } label: {
            Text("Open in Editor")
        } primaryAction: {
            if let preferred {
                openWith(preferred, absolutePath: absolutePath)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Open this file's HTML source in a code editor. Use the menu to choose which editor.")
    }

    private func openWith(_ editor: ExternalEditor.Editor, absolutePath: String) {
        ExternalEditor.open(URL(fileURLWithPath: absolutePath), with: editor) { message in
            appState.errorMessage = message
        }
    }

    /// Opens a document's source in an external editor, but flushes + confirms any unsaved
    /// in-app edits first so the external editor doesn't load stale on-disk bytes.
    private func openSourceExternally(_ editor: ExternalEditor.Editor, absolutePath: String) {
        preferredEditorBundleID = editor.bundleID
        Task {
            if editorMode == .visual { await visualBridge.flush() }
            if editorMode.isEditing, appState.hasUnsavedEdits, !(await EditorGuard.confirmLeavingEditor(appState)) {
                return
            }
            openWith(editor, absolutePath: absolutePath)
        }
    }

    private func webViewIdentity(for document: DocumentNode, vaultURL: URL) -> String {
        WebViewIdentity.make(
            vaultPath: vaultURL.standardizedFileURL.path,
            contentId: document.id,
            // Including the content hash rebuilds the preview after an in-app save: the
            // incremental reindex updates the document's hash, the identity changes, and
            // SwiftUI discards and reloads the web view (which re-fetches fresh bytes).
            contentHash: document.contentHash,
            trustMode: appState.trustMode,
            allowsNetworkAccess: appState.allowsNetworkAccess
        )
    }

    private func inboxWebViewIdentity(for item: InboxItem, vaultURL: URL) -> String {
        WebViewIdentity.make(
            vaultPath: vaultURL.standardizedFileURL.path,
            contentId: item.id,
            contentHash: item.contentHash,
            trustMode: appState.trustMode,
            allowsNetworkAccess: appState.allowsNetworkAccess
        )
    }

    /// Identity for the WYSIWYG editor's web view. Deliberately minimal — it rebuilds only on
    /// a document change or an explicit reload (conflict-reload token), never on a save (which
    /// would reset the caret/scroll) and never on a security-policy flip. Unlike the reader,
    /// the visual editor ALWAYS runs with page JS disabled regardless of trust, and its
    /// network content rules are installed in the coordinator at build time (not via this id),
    /// so a Safe↔Trusted or network toggle must NOT tear down a live edit (doing so reloads
    /// disk and drops in-progress edits). A mid-edit network change therefore keeps the
    /// editor's build-time content rules until the next load — acceptable because page JS is
    /// off, and the reader re-applies the policy on save.
    private func visualWebViewIdentity(for document: DocumentNode, vaultURL: URL) -> String {
        WebViewIdentity.make(
            vaultPath: vaultURL.standardizedFileURL.path,
            contentId: "visual|\(document.id)|\(appState.visualReloadToken.uuidString)",
            trustMode: .safe,
            allowsNetworkAccess: false
        )
    }
}

/// Opens a file's source in a code editor rather than the default `.html` handler
/// (which is usually a browser). The user picks which installed editor to use.
enum ExternalEditor {
    struct Editor: Identifiable, Hashable {
        let bundleID: String
        let name: String
        let url: URL

        var id: String { bundleID }
    }

    /// Known source editors, in display order. Only installed ones are surfaced.
    private static let catalog: [(bundleID: String, name: String)] = [
        ("com.microsoft.VSCode", "Visual Studio Code"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("dev.zed.Zed", "Zed"),
        ("com.sublimetext.4", "Sublime Text"),
        ("com.sublimetext.3", "Sublime Text 3"),
        ("com.barebones.bbedit", "BBEdit"),
        ("com.panic.Nova", "Nova"),
        ("com.macromates.TextMate", "TextMate"),
        ("com.apple.dt.Xcode", "Xcode"),
        ("com.apple.TextEdit", "TextEdit")
    ]

    @MainActor
    static func installedEditors() -> [Editor] {
        let workspace = NSWorkspace.shared
        return catalog.compactMap { entry in
            guard let url = workspace.urlForApplication(withBundleIdentifier: entry.bundleID) else { return nil }
            return Editor(bundleID: entry.bundleID, name: entry.name, url: url)
        }
    }

    @MainActor
    static func open(_ fileURL: URL, with editor: Editor, onError: @escaping (String) -> Void) {
        Task { @MainActor in
            do {
                try await NSWorkspace.shared.open(
                    [fileURL],
                    withApplicationAt: editor.url,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } catch {
                onError("Could not open \(fileURL.lastPathComponent) in \(editor.name): \(error.localizedDescription)")
            }
        }
    }
}
