import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            VaultSidebar()
                .frame(minWidth: 240)
        } content: {
            ReaderPane()
                .frame(minWidth: 520)
        } detail: {
            ContextPane()
                .frame(minWidth: 280)
        }
        .toolbar {
            Button("Open Vault") {
                chooseVault()
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
}
