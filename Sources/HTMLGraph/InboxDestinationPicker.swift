import AppKit
import HTMLGraphCore

enum InboxDestinationPicker {
    /// Asks only *which folder in the vault* to file the item into, keeping the
    /// item's existing filename. A directory picker (not a Save panel) so the
    /// action reads as "file this into the vault", not "save a new document".
    @MainActor
    static func chooseDestination(for item: InboxItem, vaultURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "File Into Vault"
        panel.message = "Choose a folder in your vault to file “\(item.title)” into."
        panel.prompt = "File Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = vaultURL

        guard panel.runModal() == .OK, let folderURL = panel.url else { return nil }

        let filename = URL(fileURLWithPath: item.path).lastPathComponent
        return folderURL.appendingPathComponent(filename)
    }
}
