import AppKit
import HTMLGraphCore
import SwiftUI

struct VaultSidebar: View {
    @EnvironmentObject private var appState: AppState

    /// Folders the user has explicitly collapsed; everything else is expanded by
    /// default so a freshly opened vault shows its structure.
    @State private var collapsedFolders: Set<String> = []

    private var isSearching: Bool {
        !appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List(selection: $appState.sidebarSelection) {
            if !appState.inboxItems.isEmpty {
                Section {
                    ForEach(appState.inboxItems) { item in
                        SidebarRowLabel(title: item.title, subtitle: item.path)
                            .tag(SidebarSelection.inbox(item.id))
                            .contextMenu { inboxContextMenu(item, appState: appState) }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Unfiled")
                        Text("\(appState.inboxItems.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            documentsSection
        }
        .listStyle(.sidebar)
        // Vault-wide actions for right-clicking empty sidebar space. Row context menus
        // take precedence over this for their own rows.
        .contextMenu {
            if appState.vaultURL != nil {
                Button("New Document…") { SidebarActions.newDocument(inFolder: nil, appState: appState) }
                Button("New Folder…") { SidebarActions.newFolder(inParent: nil, appState: appState) }
                Divider()
                Button("Reveal Vault in Finder") {
                    if let path = appState.vaultURL?.path { SidebarCommands.reveal(absolutePath: path) }
                }
            }
        }
    }

    @ViewBuilder
    private var documentsSection: some View {
        if isSearching {
            // Flat results while searching, so a match can't hide inside a collapsed folder.
            if !appState.filteredDocuments.isEmpty {
                Section("Documents") {
                    ForEach(appState.filteredDocuments) { document in
                        SidebarRowLabel(title: document.title, subtitle: document.path)
                            .tag(SidebarSelection.document(document.id))
                            .contextMenu { documentContextMenu(document, appState: appState) }
                    }
                }
            }
        } else if !appState.documentTree.isEmpty {
            Section("Documents") {
                DocumentTreeRows(nodes: appState.documentTree, collapsedFolders: $collapsedFolders)
            }
        }
    }
}

struct SidebarRowLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.body)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Recursive rows for the Documents tree. Folders render as disclosure groups;
/// documents render as selectable rows. Both carry a right-click context menu.
private struct DocumentTreeRows: View {
    @EnvironmentObject private var appState: AppState
    let nodes: [DocumentTreeNode]
    @Binding var collapsedFolders: Set<String>

    var body: some View {
        ForEach(nodes) { node in
            if let document = node.document {
                SidebarRowLabel(title: document.title, subtitle: node.name)
                    .tag(SidebarSelection.document(document.id))
                    .contextMenu { documentContextMenu(document, appState: appState) }
            } else {
                DisclosureGroup(isExpanded: expansion(for: node.id)) {
                    DocumentTreeRows(nodes: node.children, collapsedFolders: $collapsedFolders)
                } label: {
                    // Attach the folder menu to the LABEL only. A .contextMenu on the whole
                    // DisclosureGroup also captures right-clicks on its disclosed child
                    // rows, so every document inside a folder would wrongly show the folder
                    // menu instead of its own.
                    Label(node.name, systemImage: "folder")
                        .contextMenu { folderContextMenu(node) }
                }
            }
        }
    }

    @ViewBuilder
    private func folderContextMenu(_ node: DocumentTreeNode) -> some View {
        let folderPath = node.id.hasPrefix("folder:") ? String(node.id.dropFirst("folder:".count)) : node.id
        Button("New Document…") { SidebarActions.newDocument(inFolder: folderPath, appState: appState) }
        Button("New Folder…") { SidebarActions.newFolder(inParent: folderPath, appState: appState) }
        Divider()
        if let vaultURL = appState.vaultURL {
            Button("Reveal in Finder") {
                SidebarCommands.reveal(absolutePath: vaultURL.appendingPathComponent(folderPath).path)
            }
        }
        Button("Copy Path") { SidebarCommands.copyToPasteboard(folderPath) }
        Divider()
        Button("Expand All") { setCollapsed(false, for: node) }
        Button("Collapse All") { setCollapsed(true, for: node) }
    }

    private func setCollapsed(_ collapsed: Bool, for node: DocumentTreeNode) {
        for id in descendantFolderIds(node) {
            if collapsed {
                collapsedFolders.insert(id)
            } else {
                collapsedFolders.remove(id)
            }
        }
    }

    private func descendantFolderIds(_ node: DocumentTreeNode) -> [String] {
        var ids = [node.id]
        for child in node.children where child.isFolder {
            ids.append(contentsOf: descendantFolderIds(child))
        }
        return ids
    }

    private func expansion(for id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolders.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedFolders.remove(id)
                } else {
                    collapsedFolders.insert(id)
                }
            }
        )
    }
}

// MARK: - Context menus

@ViewBuilder @MainActor
private func documentContextMenu(_ document: DocumentNode, appState: AppState) -> some View {
    Button("Open in Browser") { SidebarCommands.openInBrowser(absolutePath: document.absolutePath) }
    Button("Reveal in Finder") { SidebarCommands.reveal(absolutePath: document.absolutePath) }
    Menu("Copy") {
        Button("Title") { SidebarCommands.copyToPasteboard(document.title) }
        Button("Relative Path") { SidebarCommands.copyToPasteboard(document.path) }
        Button("Full Path") { SidebarCommands.copyToPasteboard(document.absolutePath) }
        Button("As HTML Link") { SidebarCommands.copyToPasteboard(SidebarCommands.htmlLink(for: document)) }
    }
    Divider()
    Button("Duplicate") { appState.duplicateDocument(document) }
    let currentFolder = (document.path as NSString).deletingLastPathComponent
    Menu("Move to") {
        // Same items for every document so the menu shape doesn't depend on where the
        // file lives — the document's current location is disabled, not hidden.
        Button("Vault Root") { SidebarActions.move(document, to: nil, appState: appState) }
            .disabled(currentFolder.isEmpty)
        if !appState.moveTargetFolders.isEmpty {
            Divider()
            ForEach(appState.moveTargetFolders, id: \.self) { folder in
                Button(folder) { SidebarActions.move(document, to: folder, appState: appState) }
                    .disabled(folder == currentFolder)
            }
        }
    }
    Button("Rename…") { SidebarActions.rename(document, appState: appState) }
    Divider()
    Button("Move to Trash", role: .destructive) { SidebarActions.delete(document, appState: appState) }
}

@ViewBuilder @MainActor
private func inboxContextMenu(_ item: InboxItem, appState: AppState) -> some View {
    Button("Add to Vault") { appState.addToVault(item, folder: nil) }
    if !appState.moveTargetFolders.isEmpty {
        Menu("File Into") {
            ForEach(appState.moveTargetFolders, id: \.self) { folder in
                Button(folder) { appState.addToVault(item, folder: folder) }
            }
        }
    }
    Divider()
    Button("Open in Browser") { SidebarCommands.openInBrowser(absolutePath: item.absolutePath) }
    Button("Reveal in Finder") { SidebarCommands.reveal(absolutePath: item.absolutePath) }
    Button("Copy Path") { SidebarCommands.copyToPasteboard(item.path) }
    Divider()
    Button("Move to Trash", role: .destructive) { SidebarActions.deleteInbox(item, appState: appState) }
}

// MARK: - Action orchestration

/// Bridges context-menu buttons to AppState mutations, layering on the modal prompts
/// (rename/new-name text entry) and link-breakage confirmations. Kept out of AppState
/// so those methods stay pure, testable mutations — mirroring how ContentView drives the
/// inbox-accept flow through a picker before calling AppState.
@MainActor
enum SidebarActions {
    static func newDocument(inFolder folder: String?, appState: AppState) {
        let location = folder.map { "in “\($0)”" } ?? "in the vault root"
        guard let name = SidebarCommands.promptForName(
            title: "New Document",
            message: "Create a new HTML document \(location).",
            defaultValue: "Untitled",
            confirmTitle: "Create"
        ) else { return }
        appState.createDocument(inFolder: folder, named: name)
    }

    static func newFolder(inParent parent: String?, appState: AppState) {
        let location = parent.map { "inside “\($0)”" } ?? "in the vault root"
        guard let name = SidebarCommands.promptForName(
            title: "New Folder",
            message: "Create a new folder \(location).",
            defaultValue: "New Folder",
            confirmTitle: "Create"
        ) else { return }
        appState.createFolder(named: name, inParent: parent)
    }

    static func rename(_ document: DocumentNode, appState: AppState) {
        let count = appState.backlinkCount(forDocument: document.id)
        let warning = count > 0
            ? "\n\n⚠️ \(count) \(documentsWord(count)) link to this file. Renaming it will break those links."
            : ""
        guard let name = SidebarCommands.promptForName(
            title: "Rename Document",
            message: "Enter a new name for “\(document.title)”." + warning,
            defaultValue: ((document.path as NSString).lastPathComponent as NSString).deletingPathExtension,
            confirmTitle: "Rename"
        ) else { return }
        appState.renameDocument(document, to: name)
    }

    static func move(_ document: DocumentNode, to folder: String?, appState: AppState) {
        let count = appState.backlinkCount(forDocument: document.id)
        if count > 0 {
            let destination = folder ?? "the vault root"
            guard SidebarCommands.confirmDestructive(
                title: "Move will break links",
                message: "Moving “\(document.title)” to \(destination) will break \(count) inbound \(linkWord(count)).",
                confirmTitle: "Move"
            ) else { return }
        }
        appState.moveDocument(document, toFolder: folder)
    }

    static func delete(_ document: DocumentNode, appState: AppState) {
        let count = appState.backlinkCount(forDocument: document.id)
        let extra = count > 0
            ? " \(count) \(documentsWord(count)) link to it — those links will break."
            : ""
        guard SidebarCommands.confirmDestructive(
            title: "Move to Trash?",
            message: "“\(document.title)” will be moved to the Trash.\(extra)",
            confirmTitle: "Move to Trash"
        ) else { return }
        appState.trashDocument(document)
    }

    static func deleteInbox(_ item: InboxItem, appState: AppState) {
        guard SidebarCommands.confirmDestructive(
            title: "Move to Trash?",
            message: "“\(item.title)” will be moved to the Trash.",
            confirmTitle: "Move to Trash"
        ) else { return }
        appState.trashInboxItem(item)
    }

    private static func documentsWord(_ count: Int) -> String {
        count == 1 ? "document" : "documents"
    }

    private static func linkWord(_ count: Int) -> String {
        count == 1 ? "link" : "links"
    }
}

// MARK: - AppKit commands (Finder, browser, pasteboard, modal prompts)

/// Thin AppKit wrappers for sidebar actions that touch macOS services rather than the
/// vault's file tree. Modal prompts run synchronously like the app's existing
/// `NSOpenPanel` flows (VaultFolderPicker, InboxDestinationPicker).
@MainActor
enum SidebarCommands {
    static func reveal(absolutePath: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
    }

    static func openInBrowser(absolutePath: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: absolutePath))
    }

    static func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// An `<a href>` snippet pointing at the document by its vault-relative path, ready
    /// to paste into another document to link the two.
    static func htmlLink(for document: DocumentNode) -> String {
        // .urlPathAllowed leaves "&" and quotes intact, so HTML-escape them for the
        // attribute context — otherwise a path like "A&copy;.html" is decoded as an
        // entity and the pasted link silently resolves to the wrong file.
        let href = (document.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? document.path)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let title = document.title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<a href=\"\(href)\">\(title)</a>"
    }

    /// Single-field modal name prompt. Returns the trimmed value, or nil if cancelled or
    /// left empty.
    static func promptForName(title: String, message: String, defaultValue: String, confirmTitle: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Warning-style confirmation for a destructive or link-breaking action. Returns true
    /// only if the user chose the confirm button.
    static func confirmDestructive(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
