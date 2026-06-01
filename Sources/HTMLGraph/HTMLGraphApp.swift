import SwiftUI

@main
struct HTMLGraphApp: App {
    @StateObject private var appState = AppState()

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
            }
        }
    }

    private func chooseVault() {
        if let url = VaultFolderPicker.chooseVault() {
            appState.openVault(url)
        }
    }
}
