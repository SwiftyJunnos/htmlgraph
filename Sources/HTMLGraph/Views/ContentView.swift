import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            VaultStatusBar()

            Divider()

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
        }
        .toolbar {
            Button(appState.openVaultButtonTitle) {
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

private struct VaultStatusBar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: appState.vaultURL == nil ? "folder" : "folder.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(appState.vaultDisplayName ?? "No vault open")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text(appState.vaultStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }

                if let path = appState.vaultDisplayPath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
