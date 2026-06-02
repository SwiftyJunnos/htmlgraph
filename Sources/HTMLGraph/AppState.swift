import Foundation
import HTMLGraphCore
import SwiftUI

/// A single selection across the sidebar so Inbox and Documents share one
/// `List` selection. Stored as one source of truth to avoid a side-effecting
/// selection binding mutating `@Published` state during a view update.
enum SidebarSelection: Hashable {
    case inbox(String)
    case document(String)
}

/// A node in the sidebar's Documents tree: either a folder (document == nil, with
/// children) or a leaf document.
struct DocumentTreeNode: Identifiable, Hashable {
    let id: String
    let name: String
    let document: DocumentNode?
    var children: [DocumentTreeNode]

    var isFolder: Bool { document == nil }
}

/// Builds a folder hierarchy from documents' relative paths. Folders are sorted
/// before documents at each level; documents are sorted by title.
enum DocumentTreeBuilder {
    static func build(from documents: [DocumentNode]) -> [DocumentTreeNode] {
        build(documents, depth: 0, folderPrefix: "")
    }

    private static func build(_ documents: [DocumentNode], depth: Int, folderPrefix: String) -> [DocumentTreeNode] {
        var folderGroups: [String: [DocumentNode]] = [:]
        var leaves: [DocumentNode] = []

        for document in documents {
            let components = document.path.split(separator: "/").map(String.init)
            if components.count <= depth + 1 {
                leaves.append(document)
            } else {
                folderGroups[components[depth], default: []].append(document)
            }
        }

        var nodes: [DocumentTreeNode] = []

        for folderName in folderGroups.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            let childPrefix = folderPrefix.isEmpty ? folderName : "\(folderPrefix)/\(folderName)"
            let children = build(folderGroups[folderName] ?? [], depth: depth + 1, folderPrefix: childPrefix)
            nodes.append(DocumentTreeNode(id: "folder:\(childPrefix)", name: folderName, document: nil, children: children))
        }

        for document in leaves.sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) {
            let filename = (document.path as NSString).lastPathComponent
            nodes.append(DocumentTreeNode(id: document.id, name: filename, document: document, children: []))
        }

        return nodes
    }
}

/// A vault the user has opened before. Stores a security-scoped bookmark (required
/// to re-open a sandboxed user-selected folder across launches) plus a stable path
/// used as identity, de-dup key, and the UI subtitle.
struct RecentVault: Codable, Identifiable, Hashable {
    let bookmarkData: Data
    let displayName: String
    let path: String
    let lastOpened: Date

    var id: String { path }
}

/// UserDefaults-backed persistence for the recent vaults list. Pure storage — the
/// bookmark resolution + security-scoped access lifecycle lives in `AppState`.
struct RecentVaultsStore {
    static let maxCount = 10

    private let defaults: UserDefaults
    private let key = "recentVaults"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [RecentVault] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RecentVault].self, from: data)) ?? []
    }

    func save(_ vaults: [RecentVault]) {
        let capped = Array(vaults.prefix(Self.maxCount))
        if let data = try? JSONEncoder().encode(capped) {
            defaults.set(data, forKey: key)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var vaultURL: URL?
    @Published var index: VaultIndex?
    @Published var sidebarSelection: SidebarSelection?
    @Published var searchText = ""
    @Published var trustMode: VaultTrustMode = .safe {
        didSet {
            if trustMode != .trusted {
                allowsNetworkAccess = false
            }
        }
    }
    @Published var allowsNetworkAccess = false
    @Published var errorMessage: String?
    @Published var isIndexing = false
    @Published var inboxItems: [InboxItem] = []
    @Published private(set) var recentVaults: [RecentVault] = []

    private var indexingTask: Task<Void, Never>?
    private var inboxPollingTask: Task<Void, Never>?
    private var indexingGeneration = UUID()

    /// The single folder we currently hold a security-scoped access claim on.
    private var accessedVaultURL: URL?
    private let recentsStore: RecentVaultsStore

    /// A document id to select once the next index finishes (e.g. a just-created doc).
    private var pendingSelectionId: String?

    init(recentsStore: RecentVaultsStore = RecentVaultsStore()) {
        self.recentsStore = recentsStore
        self.recentVaults = recentsStore.load()
    }

    var selectedDocumentId: String? {
        if case let .document(id) = sidebarSelection { return id }
        return nil
    }

    var selectedInboxItemId: String? {
        if case let .inbox(id) = sidebarSelection { return id }
        return nil
    }

    var selectedDocument: DocumentNode? {
        guard let selectedDocumentId else { return nil }
        return index?.document(id: selectedDocumentId)
    }

    var selectedInboxItem: InboxItem? {
        guard let selectedInboxItemId else { return nil }
        return inboxItems.first { $0.id == selectedInboxItemId }
    }

    var securityPolicy: VaultSecurityPolicy {
        VaultSecurityPolicy(mode: trustMode, allowsNetworkAccess: allowsNetworkAccess)
    }

    var openVaultButtonTitle: String {
        vaultURL == nil ? "Open Vault" : "Change Vault"
    }

    var vaultDisplayName: String? {
        guard let vaultURL else { return nil }
        return vaultURL.lastPathComponent.isEmpty ? vaultURL.path : vaultURL.lastPathComponent
    }

    var vaultDisplayPath: String? {
        vaultURL?.standardizedFileURL.path
    }

    var vaultStatusText: String {
        if isIndexing {
            return "Indexing vault..."
        }

        guard vaultURL != nil else {
            return "No vault open"
        }

        let count = index?.documents.count ?? 0
        return count == 1 ? "1 document" : "\(count) documents"
    }

    var filteredDocuments: [DocumentNode] {
        let documents = index?.documents ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return documents }

        return documents.filter { document in
            document.title.localizedCaseInsensitiveContains(query) ||
                document.path.localizedCaseInsensitiveContains(query)
        }
    }

    /// Distinct relative folder paths that already contain documents (root excluded),
    /// used to offer in-app "Add to Vault" destinations without a filesystem navigator.
    var vaultFolders: [String] {
        let folders = (index?.documents ?? []).map { document in
            (document.path as NSString).deletingLastPathComponent
        }
        return Set(folders).subtracting([""]).sorted()
    }

    /// Documents arranged as a folder hierarchy for the sidebar's tree view.
    var documentTree: [DocumentTreeNode] {
        DocumentTreeBuilder.build(from: index?.documents ?? [])
    }

    /// Opens a folder the user just picked via the panel. Claims security-scoped
    /// access, records a reopenable bookmark, then starts the session.
    func openVault(_ url: URL) {
        beginAccess(url)
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            recordRecent(url: url, bookmarkData: bookmark)
        }
        beginSession(at: url)
    }

    /// Re-opens a previously recorded vault by resolving its security-scoped bookmark.
    /// Drops the entry (and, unless automatic, surfaces an error) if it can't be opened.
    func openRecent(_ recent: RecentVault, isAutomatic: Bool = false) {
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: recent.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            dropRecent(recent, automatic: isAutomatic)
            return
        }

        if accessedVaultURL != resolved {
            releaseAccess()
            guard resolved.startAccessingSecurityScopedResource() else {
                dropRecent(recent, automatic: isAutomatic)
                return
            }
            accessedVaultURL = resolved
        }

        guard directoryExists(resolved) else {
            releaseAccess()
            dropRecent(recent, automatic: isAutomatic)
            return
        }

        var bookmarkData = recent.bookmarkData
        if isStale,
           let refreshed = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarkData = refreshed
        }

        recordRecent(url: resolved, bookmarkData: bookmarkData)
        beginSession(at: resolved)
    }

    /// Shows the folder picker and opens the chosen vault. Single entry point so the
    /// AppKit panel + bookmark flow lives in one place.
    func chooseAndOpenVault() {
        if let url = VaultFolderPicker.chooseVault() {
            openVault(url)
        }
    }

    func removeRecent(_ recent: RecentVault) {
        recentVaults.removeAll { $0.path == recent.path }
        recentsStore.save(recentVaults)
    }

    func clearRecents() {
        recentVaults = []
        recentsStore.save([])
    }

    /// Shared work of opening a vault: cancel prior tasks, reset state, kick off
    /// indexing + inbox polling. Access/bookmark handling happens in the callers.
    private func beginSession(at url: URL) {
        indexingTask?.cancel()
        inboxPollingTask?.cancel()

        let generation = UUID()
        indexingGeneration = generation
        vaultURL = url
        index = nil
        sidebarSelection = nil
        errorMessage = nil
        isIndexing = true
        do {
            try refreshInbox()
        } catch {
            inboxItems = []
            errorMessage = error.localizedDescription
        }

        indexingTask = Task { [weak self] in
            do {
                let builtIndex = try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let index = try VaultIndexer().indexVault(at: url)
                    try Task.checkCancellation()
                    return index
                }.value

                guard !Task.isCancelled else { return }
                self?.finishIndexing(generation: generation, result: .success(builtIndex))
            } catch is CancellationError {
                self?.finishCancelledIndexing(generation: generation)
            } catch {
                self?.finishIndexing(generation: generation, result: .failure(error))
            }
        }

        startInboxPolling()
    }

    private func beginAccess(_ url: URL) {
        guard accessedVaultURL != url else { return }
        releaseAccess()
        _ = url.startAccessingSecurityScopedResource()
        accessedVaultURL = url
    }

    private func releaseAccess() {
        accessedVaultURL?.stopAccessingSecurityScopedResource()
        accessedVaultURL = nil
    }

    private func recordRecent(url: URL, bookmarkData: Data) {
        let standardizedPath = url.standardizedFileURL.path
        let name = url.lastPathComponent.isEmpty ? standardizedPath : url.lastPathComponent
        let entry = RecentVault(bookmarkData: bookmarkData, displayName: name, path: standardizedPath, lastOpened: Date())
        recentVaults.removeAll { $0.path.caseInsensitiveCompare(standardizedPath) == .orderedSame }
        recentVaults.insert(entry, at: 0)
        if recentVaults.count > RecentVaultsStore.maxCount {
            recentVaults = Array(recentVaults.prefix(RecentVaultsStore.maxCount))
        }
        recentsStore.save(recentVaults)
    }

    private func dropRecent(_ recent: RecentVault, automatic: Bool) {
        recentVaults.removeAll { $0.path == recent.path }
        recentsStore.save(recentVaults)
        if !automatic {
            errorMessage = "“\(recent.displayName)” could not be opened — it may have been moved or deleted. It has been removed from Recent."
        }
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func finishIndexing(generation: UUID, result: Result<VaultIndex, Error>) {
        guard generation == indexingGeneration else { return }

        isIndexing = false
        indexingTask = nil

        switch result {
        case .success(let builtIndex):
            index = builtIndex
            if let pendingSelectionId, builtIndex.document(id: pendingSelectionId) != nil {
                sidebarSelection = .document(pendingSelectionId)
            } else {
                sidebarSelection = builtIndex.documents.first.map { .document($0.id) }
            }
            pendingSelectionId = nil
            if let vaultURL {
                inboxItems = (try? InboxScanner().scanInbox(at: vaultURL)) ?? inboxItems
            }
            errorMessage = nil
        case .failure(let error):
            index = nil
            sidebarSelection = nil
            pendingSelectionId = nil
            errorMessage = error.localizedDescription
        }
    }

    private func finishCancelledIndexing(generation: UUID) {
        guard generation == indexingGeneration else { return }
        isIndexing = false
        indexingTask = nil
        pendingSelectionId = nil
    }

    deinit {
        indexingTask?.cancel()
        inboxPollingTask?.cancel()
        accessedVaultURL?.stopAccessingSecurityScopedResource()
    }

    func selectDocument(_ id: String) {
        sidebarSelection = .document(id)
    }

    func selectInboxItem(_ id: String) {
        sidebarSelection = .inbox(id)
    }

    func refreshInbox() throws {
        guard let vaultURL else {
            inboxItems = []
            if case .inbox = sidebarSelection { sidebarSelection = nil }
            return
        }

        inboxItems = try InboxScanner().scanInbox(at: vaultURL)
        if case let .inbox(id) = sidebarSelection,
           !inboxItems.contains(where: { $0.id == id }) {
            sidebarSelection = nil
        }
    }

    func acceptInboxItem(_ item: InboxItem, to destinationURL: URL) throws {
        guard let vaultURL else { return }

        try InboxAccepter().accept(item, to: destinationURL, vaultURL: vaultURL)
        try refreshInbox()
        sidebarSelection = nil
        openVault(vaultURL)
    }

    /// Promotes an unfiled item into the vault — to the root by default, or into a
    /// known folder. The folder is purely organizational: the graph is flat, so every
    /// destination yields the same node. Resolves name collisions so the one-click
    /// path never dead-ends.
    func addToVault(_ item: InboxItem, folder: String?) {
        guard let vaultURL else { return }

        let folderURL: URL
        if let folder, !folder.isEmpty {
            folderURL = vaultURL.appendingPathComponent(folder, isDirectory: true)
        } else {
            folderURL = vaultURL
        }

        let filename = (item.path as NSString).lastPathComponent
        let destinationURL = uniqueDestination(in: folderURL, filename: filename)

        do {
            try acceptInboxItem(item, to: destinationURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func uniqueDestination(in folderURL: URL, filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folderURL.appendingPathComponent(filename)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.standardizedFileURL.path) {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            candidate = folderURL.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }

    /// Creates the missing target of an unresolved HTML link as a stub document,
    /// then re-indexes and selects it. No-op for non-HTML or unresolvable targets.
    func createDocument(forUnresolved edge: LinkEdge) {
        guard let vaultURL, let relativePath = edge.normalizedTargetPath else { return }
        let ext = (relativePath as NSString).pathExtension.lowercased()
        guard ext == "html" || ext == "htm" else { return }

        let fileURL = vaultURL.appendingPathComponent(relativePath)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let filename = (relativePath as NSString).lastPathComponent
            let title = edge.linkText.isEmpty ? (filename as NSString).deletingPathExtension : edge.linkText
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Self.stubHTML(title: title).write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        pendingSelectionId = relativePath
        beginSession(at: vaultURL)
    }

    private static func stubHTML(title: String) -> String {
        let safe = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <title>\(safe)</title>
        </head>
        <body>
            <h1>\(safe)</h1>
        </body>
        </html>
        """
    }

    private func startInboxPolling() {
        inboxPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    try self?.refreshInbox()
                } catch is CancellationError {
                    return
                } catch {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
