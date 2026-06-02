import AppKit
import HTMLGraphCore

enum InboxDestinationPicker {
    @MainActor
    static func chooseDestination(for item: InboxItem, vaultURL: URL) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Accept Inbox Item"
        panel.prompt = "Accept"
        panel.nameFieldLabel = "Save As:"
        panel.nameFieldStringValue = URL(fileURLWithPath: item.path).lastPathComponent
        panel.directoryURL = vaultURL
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        return panel.runModal() == .OK ? panel.url : nil
    }
}
