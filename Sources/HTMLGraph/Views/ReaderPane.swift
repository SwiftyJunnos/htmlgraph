import SwiftUI

struct ReaderPane: View {
    @EnvironmentObject private var appState: AppState

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

                    Text(appState.trustMode == .safe ? "Safe Mode" : "Trusted Mode")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

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
                        onInternalNavigation: { relativePath in
                            appState.selectDocument(relativePath)
                        },
                        onExternalNavigation: { url in
                            let didOpen = NSWorkspace.shared.open(url)
                            if !didOpen {
                                appState.errorMessage = "Could not open \(url.absoluteString) in the default external app."
                            }
                        }
                    )
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
                ContentUnavailableView(
                    "Open a vault",
                    systemImage: "folder",
                    description: Text("Choose a local HTML folder to begin.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
