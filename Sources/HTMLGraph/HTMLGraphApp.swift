import SwiftUI

@main
struct HTMLGraphApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Vault...") {
                    chooseVault()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Global Graph") {
                    openWindow(id: "global-graph")
                }
                .keyboardShortcut("g", modifiers: .command)
            }
        }

        Window("Global Graph", id: "global-graph") {
            GlobalGraphView()
                .environmentObject(appState)
        }
    }

    private func chooseVault() {
        if let url = VaultFolderPicker.chooseVault() {
            appState.openVault(url)
        }
    }
}
