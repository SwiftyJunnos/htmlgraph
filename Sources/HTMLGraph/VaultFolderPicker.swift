import AppKit

enum VaultFolderPicker {
    @MainActor
    static func chooseVault() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Vault"

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
