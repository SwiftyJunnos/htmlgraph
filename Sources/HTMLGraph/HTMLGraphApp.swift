import SwiftUI

@main
struct HTMLGraphApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow
    @AppStorage("autoReopenLastVault") private var autoReopenLastVault = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1100, minHeight: 720)
                .task {
                    if autoReopenLastVault,
                       appState.vaultURL == nil,
                       let mostRecent = appState.recentVaults.first {
                        appState.openRecent(mostRecent, isAutomatic: true)
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Vault...") {
                    appState.chooseAndOpenVault()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Global Graph") {
                    openWindow(id: "global-graph")
                }
                .keyboardShortcut("g", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Menu("Open Recent") {
                    ForEach(appState.recentVaults) { recent in
                        Button(recent.displayName) {
                            appState.openRecent(recent)
                        }
                    }
                    if !appState.recentVaults.isEmpty {
                        Divider()
                        Button("Clear Menu") {
                            appState.clearRecents()
                        }
                    }
                }
                .disabled(appState.recentVaults.isEmpty)

                Toggle("Reopen Last Vault on Launch", isOn: $autoReopenLastVault)
            }
        }

        Window("Global Graph", id: "global-graph") {
            GlobalGraphView()
                .environmentObject(appState)
        }
    }
}
