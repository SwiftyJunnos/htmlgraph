import HTMLGraphCore
import SwiftUI

struct ReaderPane: View {
    @EnvironmentObject private var appState: AppState
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

                    Button("Open External") {
                        let didOpen = NSWorkspace.shared.open(URL(fileURLWithPath: item.absolutePath))
                        if !didOpen {
                            appState.errorMessage = "Could not open \(item.path) in the default external app."
                        }
                    }
                }
                .padding()

                Divider()

                if let vaultURL = appState.vaultURL {
                    HTMLDocumentWebView(
                        documentURL: URL(fileURLWithPath: item.absolutePath),
                        vaultURL: vaultURL,
                        policy: appState.securityPolicy,
                        knownDocumentIds: Set(appState.index?.documents.map(\.id) ?? []),
                        onInternalNavigation: { relativePath in
                            appState.selectDocument(relativePath)
                        },
                        onExternalNavigation: { url in
                            let didOpen = NSWorkspace.shared.open(url)
                            if !didOpen {
                                appState.errorMessage = "Could not open \(url.absoluteString) in the default external app."
                            }
                        },
                        onNavigationError: { message in
                            appState.errorMessage = message
                        }
                    )
                    .id(inboxWebViewIdentity(for: item, vaultURL: vaultURL))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                    Button("Open External") {
                        let didOpen = NSWorkspace.shared.open(URL(fileURLWithPath: document.absolutePath))
                        if !didOpen {
                            appState.errorMessage = "Could not open \(document.path) in the default external app."
                        }
                    }
                }
                .padding()

                Divider()

                if let vaultURL = appState.vaultURL {
                    HTMLDocumentWebView(
                        documentURL: URL(fileURLWithPath: document.absolutePath),
                        vaultURL: vaultURL,
                        policy: appState.securityPolicy,
                        knownDocumentIds: Set(appState.index?.documents.map(\.id) ?? []),
                        onInternalNavigation: { relativePath in
                            appState.selectDocument(relativePath)
                        },
                        onExternalNavigation: { url in
                            let didOpen = NSWorkspace.shared.open(url)
                            if !didOpen {
                                appState.errorMessage = "Could not open \(url.absoluteString) in the default external app."
                            }
                        },
                        onNavigationError: { message in
                            appState.errorMessage = message
                        }
                    )
                    .id(webViewIdentity(for: document, vaultURL: vaultURL))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            Label("Open Vault", systemImage: "folder")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityLabel("Open Vault")
                        .help("Choose a local HTML folder to open as a vault.")
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
    }

    private func webViewIdentity(for document: DocumentNode, vaultURL: URL) -> String {
        [
            vaultURL.standardizedFileURL.path,
            document.id,
            appState.trustMode.rawValue,
            String(appState.allowsNetworkAccess)
        ].joined(separator: "|")
    }

    private func inboxWebViewIdentity(for item: InboxItem, vaultURL: URL) -> String {
        [
            vaultURL.standardizedFileURL.path,
            item.id,
            item.contentHash,
            appState.trustMode.rawValue,
            String(appState.allowsNetworkAccess)
        ].joined(separator: "|")
    }
}
