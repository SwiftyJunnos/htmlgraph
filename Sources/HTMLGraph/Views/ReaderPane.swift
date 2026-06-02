import HTMLGraphCore
import SwiftUI

struct ReaderPane: View {
    @EnvironmentObject private var appState: AppState
    let onChooseVault: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.isIndexing {
                ProgressView("Indexing vault...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                    Picker("Trust", selection: $appState.trustMode) {
                        Text("Safe").tag(VaultTrustMode.safe)
                        Text("Trusted").tag(VaultTrustMode.trusted)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)

                    Toggle("Network", isOn: $appState.allowsNetworkAccess)
                        .toggleStyle(.switch)
                        .disabled(appState.trustMode != .trusted)
                        .help("Network access is controlled separately from Trusted Mode.")

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
}
