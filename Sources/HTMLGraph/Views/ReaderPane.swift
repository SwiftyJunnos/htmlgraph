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

struct ReaderPane: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("preferredEditorBundleID") private var preferredEditorBundleID = ""
    let onChooseVault: () -> Void
    let onAcceptInboxItem: (InboxItem) -> Void

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
                            appState.addToVault(item, folder: nil)
                        }
                        if !appState.vaultFolders.isEmpty {
                            Divider()
                            ForEach(appState.vaultFolders, id: \.self) { folder in
                                Button(folder) {
                                    appState.addToVault(item, folder: folder)
                                }
                            }
                        }
                        Divider()
                        Button("Choose Folder…") {
                            onAcceptInboxItem(item)
                        }
                    } primaryAction: {
                        appState.addToVault(item, folder: nil)
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
                        Text(document.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(document.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    openInEditorButton(absolutePath: document.absolutePath)
                }
                .padding()

                Divider()

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
                    ContentUnavailableView(
                        "No vault selected",
                        systemImage: "folder",
                        description: Text("Choose a local HTML folder to render this document.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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

    private func webViewIdentity(for document: DocumentNode, vaultURL: URL) -> String {
        WebViewIdentity.make(
            vaultPath: vaultURL.standardizedFileURL.path,
            contentId: document.id,
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
