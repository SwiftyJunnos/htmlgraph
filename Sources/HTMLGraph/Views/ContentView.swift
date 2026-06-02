import HTMLGraphCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            VaultSidebar()
                .frame(minWidth: 240)
        } content: {
            ReaderPane {
                chooseVault()
            } onAcceptInboxItem: { item in
                acceptInboxItem(item)
            }
            .frame(minWidth: 520)
        } detail: {
            ContextPane()
                .frame(minWidth: 280)
        }
        .navigationTitle(appState.vaultDisplayName ?? "HTMLGraph")
        .navigationSubtitle(appState.vaultStatusText)
        .searchable(text: $appState.searchText, placement: .sidebar, prompt: "Search documents")
        .toolbar {
            if appState.vaultURL != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        chooseVault()
                    } label: {
                        Label(appState.openVaultButtonTitle, systemImage: "folder")
                    }
                    .help("Choose a different local HTML folder to open as a vault.")
                }
            }
        }
        .alert("HTMLGraph Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    appState.errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    private func chooseVault() {
        if let url = VaultFolderPicker.chooseVault() {
            appState.openVault(url)
        }
    }

    private func acceptInboxItem(_ item: InboxItem) {
        guard let vaultURL = appState.vaultURL,
              let destinationURL = InboxDestinationPicker.chooseDestination(for: item, vaultURL: vaultURL) else {
            return
        }

        do {
            try appState.acceptInboxItem(item, to: destinationURL)
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}
