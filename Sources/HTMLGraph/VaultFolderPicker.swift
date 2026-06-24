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

    @MainActor
    static func chooseStaticSiteExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose an empty folder, or an existing HTMLGraph web export folder."

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
