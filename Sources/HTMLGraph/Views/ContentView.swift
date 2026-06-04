import HTMLGraphCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsSecurityPopover = false
    @AppStorage("showsContextPanel") private var showsContextPanel = true

    var body: some View {
        NavigationSplitView {
            VaultSidebar()
                .searchable(text: $appState.searchText, placement: .sidebar, prompt: "Search documents")
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            ReaderPane {
                chooseVault()
            } onAcceptInboxItem: { item in
                acceptInboxItem(item)
            }
        }
        // The context panel (backlinks / unresolved / local graph) lives in a native
        // inspector so it gets the same collapse/expand affordance the leading sidebar
        // already has. The toolbar button below toggles it, and the binding is persisted
        // so the choice sticks across launches.
        .inspector(isPresented: $showsContextPanel) {
            ContextPane()
                .inspectorColumnWidth(min: 220, ideal: 280, max: 720)
        }
        .navigationTitle(appState.vaultDisplayName ?? "HTMLGraph")
        .navigationSubtitle(appState.vaultStatusText)
        .toolbar {
            if appState.vaultURL != nil {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showsSecurityPopover = true
                    } label: {
                        Label(
                            appState.trustMode == .trusted ? "Trusted" : "Safe",
                            systemImage: appState.trustMode == .trusted ? "lock.shield.fill" : "lock.shield"
                        )
                    }
                    .help("Document rendering security — JavaScript and network access.")
                    .popover(isPresented: $showsSecurityPopover, arrowEdge: .bottom) {
                        SecuritySettingsView()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        chooseVault()
                    } label: {
                        Label(appState.openVaultButtonTitle, systemImage: "folder")
                    }
                    .help("Choose a different local HTML folder to open as a vault.")
                }
            }

            // Trailing toggle for the context inspector — mirrors the leading sidebar
            // toggle macOS provides automatically. Always available so the panel can be
            // hidden even before a vault is open.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsContextPanel.toggle()
                } label: {
                    Label("Context Panel", systemImage: "sidebar.right")
                }
                .help("Show or hide the context panel — backlinks, unresolved links, and the local graph.")
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
        appState.chooseAndOpenVault()
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

/// Global rendering-security controls, shown in a toolbar popover so their app-wide
/// scope is clear and each option can carry an explanation.
private struct SecuritySettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Trust")
                    .font(.headline)
                Picker("Trust", selection: $appState.trustMode) {
                    Text("Safe").tag(VaultTrustMode.safe)
                    Text("Trusted").tag(VaultTrustMode.trusted)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Safe renders documents statically. Trusted lets a document run JavaScript — use it only for documents you trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Allow network access", isOn: $appState.allowsNetworkAccess)
                    .disabled(appState.trustMode != .trusted)
                Text("Lets documents load remote resources and connect out. Requires Trusted mode, so enabling it also lets documents run JavaScript. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
