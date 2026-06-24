import Foundation
import HTMLGraphCore
import OSLog
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
    static func build(from documents: [DocumentNode], extraFolders: [String] = []) -> [DocumentTreeNode] {
        var nodes = build(documents, depth: 0, folderPrefix: "")
        for folder in extraFolders.sorted() {
            let components = folder.split(separator: "/").map(String.init)
            nodes = inserting(folderComponents: components, into: nodes, prefix: "")
        }
        return nodes
    }

    /// Ensures the folder path described by `folderComponents` exists as folder nodes,
    /// creating only the missing levels (idempotent for already-present folders) while
    /// keeping each level's "folders first, sorted by name, then documents" order.
    private static func inserting(folderComponents: [String], into nodes: [DocumentTreeNode], prefix: String) -> [DocumentTreeNode] {
        guard let head = folderComponents.first else { return nodes }
        let childPrefix = prefix.isEmpty ? head : "\(prefix)/\(head)"
        let rest = Array(folderComponents.dropFirst())
        var result = nodes

        if let index = result.firstIndex(where: { $0.isFolder && $0.name == head }) {
            var node = result[index]
            node.children = inserting(folderComponents: rest, into: node.children, prefix: childPrefix)
            result[index] = node
        } else {
            let children = inserting(folderComponents: rest, into: [], prefix: childPrefix)
            let newNode = DocumentTreeNode(id: "folder:\(childPrefix)", name: head, document: nil, children: children)
            let insertionIndex = result.firstIndex { existing in
                existing.isFolder
                    ? existing.name.localizedCaseInsensitiveCompare(head) == .orderedDescending
                    : true // first document — folders sort ahead of documents
            } ?? result.count
            result.insert(newNode, at: insertionIndex)
        }
        return result
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

/// The security posture a user chose for a particular vault: whether documents may
/// run JavaScript (trust) and reach the network. Remembered so reopening a vault
/// restores the same posture instead of silently dropping back to Safe.
struct VaultSecuritySettings: Codable, Equatable {
    var trustMode: VaultTrustMode
    var allowsNetworkAccess: Bool
}

/// UserDefaults-backed map of vault path -> remembered security settings. Pure
/// storage, keyed by the same standardized path `RecentVault` uses as identity.
struct VaultSecurityStore {
    private let defaults: UserDefaults
    private let key = "vaultSecuritySettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func loadAll() -> [String: VaultSecuritySettings] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: VaultSecuritySettings].self, from: data)) ?? [:]
    }

    func settings(forPath path: String) -> VaultSecuritySettings? {
        loadAll()[path]
    }

    func save(_ settings: VaultSecuritySettings, forPath path: String) {
        var all = loadAll()
        all[path] = settings
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Lifecycle of the on-device semantic index for the current vault.
enum SemanticIndexState: Equatable {
    /// No vault open / nothing built yet.
    case idle
    /// Downloading the embedding model's assets (one-time, first use).
    case preparingAssets
    /// Building the index. `progress` is in `0...1` (0 when indeterminate).
    case building(progress: Double)
    /// Index is ready to answer semantic queries.
    case ready
    /// No on-device model, or assets couldn't be obtained — UI keeps lexical search.
    case unavailable
}

@MainActor
final class AppState: ObservableObject {
    private static let exportLogger = Logger(subsystem: "com.junnos.htmlgraph", category: "VaultIndexExport")
    private static let agentGuideLogger = Logger(subsystem: "com.junnos.htmlgraph", category: "AgentGuide")
    private nonisolated static let embeddingLogger = Logger(subsystem: "com.junnos.htmlgraph", category: "SemanticIndex")

    @Published var vaultURL: URL?
    /// Loopback origin (`http://127.0.0.1:<port>/<token>/`) the current vault is served
    /// from. Documents render from this so third-party web embeds get a real web origin.
    @Published var vaultBaseURL: URL?
    /// True when the loopback preview server failed to start for the current vault.
    /// Separate from `errorMessage` so a successful index doesn't erase it (which would
    /// otherwise leave the reader stuck on an unexplained "Preparing preview…").
    @Published var previewServerFailed = false
    @Published var index: VaultIndex?
    @Published var sidebarSelection: SidebarSelection? {
        didSet { networkBlockedNotice = false }
    }
    @Published var searchText = ""
    @Published var trustMode: VaultTrustMode = .safe {
        didSet {
            if trustMode != .trusted {
                allowsNetworkAccess = false
            }
            persistSecuritySettingsIfNeeded()
        }
    }
    @Published var allowsNetworkAccess = false {
        didSet {
            if allowsNetworkAccess { networkBlockedNotice = false }
            persistSecuritySettingsIfNeeded()
        }
    }
    @Published var errorMessage: String?
    /// Set when the current document was prevented from loading remote content
    /// because the vault has network access turned off. Drives the in-reader
    /// "Allow Network Access" banner; cleared on selection change and when granted.
    @Published var networkBlockedNotice = false
    @Published var isIndexing = false
    @Published var inboxItems: [InboxItem] = []
    @Published private(set) var recentVaults: [RecentVault] = []
    /// Folders the user created in-session that don't yet contain a document. The
    /// sidebar tree is derived from documents, so without this a freshly made empty
    /// folder would be invisible — a right-click dead end. Cleared on vault switch and
    /// pruned automatically once a real document lands inside.
    @Published var pendingEmptyFolders: Set<String> = []

    /// Live in-app editing state for the selected document's HTML source, or nil when not
    /// editing. Held here (not in a view) so the buffer survives transient view rebuilds —
    /// a reindex flipping `isIndexing`, the inbox poll, or the preview web view rebuilding
    /// must never drop unsaved text.
    @Published var editorBuffer: EditorBuffer?
    /// Set when a save found the file changed on disk since it was opened; drives the
    /// Overwrite / Reload / Cancel conflict alert.
    @Published var editorConflict: EditorConflict?
    /// Bumped to force the WYSIWYG editor's web view to rebuild and reload from disk — the
    /// visual editor is deliberately NOT keyed on the document's content hash (so an ordinary
    /// save doesn't reset the caret), so a conflict-reload needs this explicit nudge.
    @Published var visualReloadToken = UUID()
    /// True only while a WYSIWYG (visual) edit session is live. Gates `updateVisualEditedDocument`
    /// so a snapshot posted by an outgoing visual editor can't bleed into a buffer that has since
    /// switched to source editing on the same document (which would overwrite the source view
    /// with re-serialized HTML).
    private var visualSessionActive = false
    /// True between starting (or reloading) a visual session and receiving its first snapshot.
    /// That first snapshot is the *unedited* DOM, re-serialized by WebKit; we adopt it as the
    /// buffer's clean reference so formatting-only differences from the on-disk bytes don't make
    /// an untouched document look edited.
    private var awaitingVisualBaseline = false

    private var indexingTask: Task<Void, Never>?
    private var inboxPollingTask: Task<Void, Never>?
    private var indexingGeneration = UUID()

    /// The single folder we currently hold a security-scoped access claim on.
    private var accessedVaultURL: URL?
    private let recentsStore: RecentVaultsStore
    private let securityStore: VaultSecurityStore
    /// True while restoring a vault's saved security posture, so the property
    /// `didSet`s don't immediately persist the value we just loaded back.
    private var isApplyingVaultSecurity = false

    /// Serves the current vault's files over loopback HTTP so documents render from a
    /// real web origin. Outlives individual web views, so it lives here in AppState.
    private let httpServer = VaultHTTPServer()

    /// A document id to select once the next index finishes (e.g. a just-created doc).
    private var pendingSelectionId: String?

    // MARK: - Semantic search (Phase 0.2)

    /// On-device embedding provider, or nil if the OS has no model for the content —
    /// then semantic search stays `.unavailable` and the UI keeps lexical search.
    private let embeddingProvider: EmbeddingProvider? = NLContextualEmbeddingProvider()
    private let embeddingStore = VaultEmbeddingStore()
    /// In-memory embedding index for the current vault, kept current by the re-embed
    /// hooks below. Read by the (Phase 0.3) semantic search.
    @Published private(set) var embeddingIndex: EmbeddingIndex?
    /// Lifecycle state for semantic search; drives the Phase 0.3 UI fallback.
    @Published private(set) var semanticIndexState: SemanticIndexState = .idle
    /// Guards background re-embed results so a superseded vault-open or edit can't
    /// publish a stale index (mirrors `indexingGeneration` for the lexical index).
    private var embeddingGeneration = UUID()

    /// Ranked semantic hits for the current query, mapped back to documents.
    @Published private(set) var semanticResults: [DocumentNode] = []
    /// True while a semantic query is being embedded/ranked (drives the quiet
    /// "Searching…" row).
    @Published private(set) var isSearchingSemantically = false
    /// Drops the results of a superseded keystroke so a stale query can't publish.
    private var searchGeneration = UUID()
    private var searchTask: Task<Void, Never>?

    init(
        recentsStore: RecentVaultsStore = RecentVaultsStore(),
        securityStore: VaultSecurityStore = VaultSecurityStore()
    ) {
        self.recentsStore = recentsStore
        self.securityStore = securityStore
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

    /// Grants the current vault network access. Network access requires Trusted
    /// mode, so both flags move together. The rendered web view reloads on its own
    /// because its identity includes the trust mode and network flag.
    func enableNetworkAccess() {
        trustMode = .trusted
        allowsNetworkAccess = true
        networkBlockedNotice = false
    }

    /// Restores the security posture remembered for `url`, defaulting to Safe for a
    /// vault we've never seen. Suppresses persistence so loading doesn't re-save.
    private func applyStoredSecuritySettings(for url: URL) {
        let stored = securityStore.settings(forPath: url.standardizedFileURL.path)
            ?? VaultSecuritySettings(trustMode: .safe, allowsNetworkAccess: false)
        isApplyingVaultSecurity = true
        trustMode = stored.trustMode
        // Network access is only meaningful in Trusted mode; clamp defensively.
        allowsNetworkAccess = stored.trustMode == .trusted && stored.allowsNetworkAccess
        isApplyingVaultSecurity = false
    }

    /// Persists the live trust/network posture for the open vault. No-op while a
    /// restore is in flight or when no vault is open (e.g. app-launch defaults).
    private func persistSecuritySettingsIfNeeded() {
        guard !isApplyingVaultSecurity, let url = vaultURL else { return }
        securityStore.save(
            VaultSecuritySettings(trustMode: trustMode, allowsNetworkAccess: allowsNetworkAccess),
            forPath: url.standardizedFileURL.path
        )
    }

    var openVaultButtonTitle: String {
        vaultURL == nil ? "Open Vault" : "Change Vault"
    }

    /// SF Symbol for the open/change-vault action. The directional "arrow into a
    /// folder" glyph reads as "open a vault", but it only exists on macOS 26+, so we
    /// fall back to folder-with-plus on the macOS 14 deployment floor where using the
    /// newer name would render as a blank/missing symbol.
    var openVaultSymbolName: String {
        if #available(macOS 26.0, *) {
            "arrow.forward.folder"
        } else {
            "folder.badge.plus"
        }
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

    /// Folders the sidebar's "Move to" / "File Into" menus can target: every folder
    /// that already holds a document, plus any in-session empty folders the user made.
    var moveTargetFolders: [String] {
        Set(vaultFolders).union(pendingEmptyFolders)
            .filter { !isInboxRelativePath($0) }
            .sorted()
    }

    /// Documents arranged as a folder hierarchy for the sidebar's tree view. Empty
    /// folders the user just created are merged in until a document lands inside them.
    var documentTree: [DocumentTreeNode] {
        let documents = index?.documents ?? []
        let extraFolders = pendingEmptyFolders.filter { folder in
            !documents.contains { $0.path == folder || $0.path.hasPrefix(folder + "/") }
        }
        return DocumentTreeBuilder.build(from: documents, extraFolders: Array(extraFolders))
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
        // Trust and network access are per-vault and remembered across launches. On an
        // actual vault change, restore the posture the user last chose for this vault
        // (Safe by default). Same-vault reindexes (creating a doc, accepting an inbox
        // item) keep the live settings so an enabled session isn't silently revoked.
        let isDifferentVault = vaultURL?.standardizedFileURL.path
            .caseInsensitiveCompare(url.standardizedFileURL.path) != .orderedSame

        indexingTask?.cancel()
        inboxPollingTask?.cancel()

        let generation = UUID()
        indexingGeneration = generation
        vaultURL = url
        if isDifferentVault {
            applyStoredSecuritySettings(for: url)
            pendingEmptyFolders = []
        }
        index = nil
        sidebarSelection = nil
        // Drop the previous vault's semantic index and invalidate any in-flight
        // re-embed so its result can't land in this session.
        embeddingIndex = nil
        semanticIndexState = .idle
        embeddingGeneration = UUID()
        searchTask?.cancel()
        semanticResults = []
        isSearchingSemantically = false
        // Any in-app edit belongs to the index we're about to discard. Callers that can
        // reach here with a dirty buffer are gated by `EditorGuard` first (save/discard),
        // so clearing it here only drops an already-clean or intentionally-abandoned buffer.
        editorBuffer = nil
        editorConflict = nil
        errorMessage = nil
        isIndexing = true

        vaultBaseURL = nil
        previewServerFailed = false
        httpServer.start(vaultURL: url) { [weak self] base in
            Task { @MainActor in
                guard let self, self.vaultURL == url else { return }
                self.vaultBaseURL = base
                // Tracked separately from errorMessage so a successful index doesn't
                // erase it (finishIndexing clears errorMessage unconditionally).
                self.previewServerFailed = (base == nil)
            }
        }
        Task {
            do {
                try await refreshInbox()
            } catch {
                inboxItems = []
                errorMessage = error.localizedDescription
            }
        }

        indexingTask = Task { [weak self] in
            do {
                let builtIndex = try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let index = try await VaultIndexer().indexVault(fileSystem: LocalFileSystem(root: url))
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
            if let vaultURL {
                // Drop in-session empty folders that have since gained a document (now
                // shown via the index) or vanished from disk (deleted out-of-band), so
                // the overlay can't resurrect or ghost a folder.
                pendingEmptyFolders = pendingEmptyFolders.filter { folder in
                    let directory = vaultURL.appendingPathComponent(folder, isDirectory: true)
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
                    let hasDocument = builtIndex.documents.contains { $0.path == folder || $0.path.hasPrefix(folder + "/") }
                    return exists && !hasDocument
                }
                // Best-effort: emit the machine-readable graph sidecar for AI tools.
                // A write failure must never break indexing and must not touch
                // errorMessage (cleared on success below) — just log it so a missing
                // sidecar is diagnosable.
                Task {
                    do {
                        try await VaultIndexExporter().export(builtIndex, vaultURL: vaultURL)
                    } catch {
                        Self.exportLogger.error("graph.json export failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                // Best-effort, create-only: drop AGENTS.md / CLAUDE.md at the vault root so
                // AI coding agents that open this folder know it's an HTMLGraph vault and how
                // to work in it. Never overwrites existing files (preserving user edits) and,
                // like the graph export, never breaks indexing or touches errorMessage.
                Task {
                    do {
                        try await VaultAgentGuideWriter().writeIfMissing(vaultURL: vaultURL)
                    } catch {
                        Self.agentGuideLogger.error("agent guide write failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                // Best-effort, off-main: refresh the on-device semantic index. Never
                // blocks indexing (exactly like the graph.json export above).
                rebuildEmbeddingIndex(for: builtIndex, vaultURL: vaultURL)
            }
            if let pendingSelectionId, builtIndex.document(id: pendingSelectionId) != nil {
                sidebarSelection = .document(pendingSelectionId)
            } else {
                sidebarSelection = builtIndex.documents.first.map { .document($0.id) }
            }
            pendingSelectionId = nil
            if let vaultURL {
                Task {
                    if let scanned = try? await InboxScanner().scanInbox(at: vaultURL) {
                        inboxItems = scanned
                    }
                }
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

    // MARK: - Agent guide

    /// Force-rewrites the vault's `AGENTS.md` / `CLAUDE.md` from HTMLGraph's current
    /// template — the explicit counterpart to the create-only write that runs on open.
    /// Overwrites any manual edits, so the UI confirms before calling this. Runs the write
    /// off the main actor; failures surface via `errorMessage` (a successful reindex clears
    /// it, which is fine for a transient write error).
    func regenerateAgentGuide() {
        guard let vaultURL else { return }
        Task {
            do {
                try await VaultAgentGuideWriter().regenerate(vaultURL: vaultURL)
                Self.agentGuideLogger.info("regenerated agent guide for vault")
            } catch {
                Self.agentGuideLogger.error("agent guide regenerate failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = "Couldn’t regenerate the agent guide: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Semantic index lifecycle (Phase 0.2)

    private func makeSemanticIndexer() -> SemanticIndexer? {
        guard let embeddingProvider else { return nil }
        return SemanticIndexer(provider: embeddingProvider, store: embeddingStore)
    }

    /// Shortest query that runs a semantic pass. Embedding a 1-character query is mostly
    /// noise for the cost, and the instant lexical title section already covers that intent
    /// — so the Meaning section stays quiet until there's at least this much signal. Counted
    /// in grapheme clusters, so one Hangul syllable counts as one (a 2-syllable Korean query
    /// or a 2-letter Latin query both qualify).
    private static let minimumSemanticQueryLength = 2

    /// Debounced semantic query: embeds the query off-main, cosine+centrality ranks it
    /// against the current embedding index, and publishes the matching documents. Runs
    /// alongside the lexical title search (the sidebar shows both as separate sections) for
    /// queries of at least `minimumSemanticQueryLength`. Generation-guarded so a stale
    /// keystroke's results are dropped. A no-op (clears results) for shorter queries or
    /// without a ready index.
    func runSemanticSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard query.count >= Self.minimumSemanticQueryLength,
              let embeddingIndex, let graph = index, let indexer = makeSemanticIndexer() else {
            withoutSearchAnimation {
                semanticResults = []
                isSearchingSemantically = false
            }
            return
        }

        let generation = UUID()
        searchGeneration = generation

        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000) // debounce keystrokes
            if Task.isCancelled { return }
            // Flip the "searching" flag only after the debounce survives, so keystrokes that
            // are superseded mid-burst never cause a list relayout. Fewer relayouts while
            // typing means fewer chances for the row animation to strand an overlapping row.
            await MainActor.run {
                guard let self, self.searchGeneration == generation else { return }
                self.withoutSearchAnimation { self.isSearchingSemantically = true }
            }
            let hits = (try? await indexer.search(query: query, in: embeddingIndex, graph: graph, topK: 50)) ?? []
            await MainActor.run {
                guard let self, self.searchGeneration == generation else { return }
                let byId = Dictionary(self.index?.documents.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
                self.withoutSearchAnimation {
                    self.semanticResults = hits.compactMap { byId[$0.documentId] }
                    self.isSearchingSemantically = false
                }
            }
        }
    }

    /// Publishes search-state mutations without SwiftUI's implicit list animation. The
    /// sidebar's `List(.sidebar)` is backed by an AppKit outline view that animates row
    /// insert/remove; when the result set churns faster than the animation settles, an
    /// outgoing and an incoming row briefly share one row frame and render overlapping.
    /// Disabling the animation at the mutation source makes the re-diff snap instead.
    private func withoutSearchAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    /// Rebuilds the whole semantic index off-main after a full reindex. Re-embeds only
    /// documents whose content changed (cache hit otherwise) and prunes ghosts.
    /// Generation-guarded so a superseded vault-open drops its result.
    private func rebuildEmbeddingIndex(for index: VaultIndex, vaultURL: URL) {
        guard let indexer = makeSemanticIndexer() else {
            semanticIndexState = .unavailable
            return
        }
        let generation = UUID()
        embeddingGeneration = generation
        semanticIndexState = .building(progress: 0)

        Task(priority: .utility) { [weak self, indexer, index, vaultURL, generation] in
            do {
                let result = try await indexer.refresh(index: index, fileSystem: LocalFileSystem(root: vaultURL))
                guard let self, self.embeddingGeneration == generation else { return }
                self.embeddingIndex = result
                self.semanticIndexState = .ready
            } catch {
                guard let self, self.embeddingGeneration == generation else { return }
                self.embeddingIndex = nil
                self.semanticIndexState = .unavailable
                Self.embeddingLogger.error("embedding refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Re-embeds exactly one document after an in-app save, off-main, and patches the
    /// in-memory index + sidecar. Bumps the generation so any in-flight full rebuild is
    /// invalidated (the just-saved vector must win). No-op until a full index exists.
    private func refreshEmbedding(forDocumentId documentId: String, in index: VaultIndex, vaultURL: URL) {
        guard let indexer = makeSemanticIndexer(),
              embeddingIndex != nil,
              let document = index.document(id: documentId) else { return }
        let generation = UUID()
        embeddingGeneration = generation

        Task(priority: .utility) { [weak self, indexer, document, documentId, vaultURL, generation] in
            do {
                let record = try await indexer.embedRecord(for: document, fileSystem: LocalFileSystem(root: vaultURL))
                guard let self, self.embeddingGeneration == generation,
                      var current = self.embeddingIndex else { return }
                current.entries[documentId] = record
                self.embeddingIndex = current
                self.persistEmbeddingIndex(to: vaultURL)
            } catch {
                Self.embeddingLogger.error("incremental embedding failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Persists the current in-memory embedding index to its sidecar, off-main.
    private func persistEmbeddingIndex(to vaultURL: URL) {
        guard let snapshot = embeddingIndex else { return }
        let store = embeddingStore
        Task.detached(priority: .utility) {
            do {
                try await store.save(
                    snapshot.entries,
                    providerId: snapshot.providerId,
                    dimension: snapshot.dimension,
                    fileSystem: LocalFileSystem(root: vaultURL)
                )
            } catch {
                Self.embeddingLogger.error("embedding persist failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    deinit {
        indexingTask?.cancel()
        inboxPollingTask?.cancel()
        searchTask?.cancel()
        httpServer.stop()
        accessedVaultURL?.stopAccessingSecurityScopedResource()
    }

    func selectDocument(_ id: String) {
        sidebarSelection = .document(id)
    }

    func selectInboxItem(_ id: String) {
        sidebarSelection = .inbox(id)
    }

    func refreshInbox() async throws {
        guard let vaultURL else {
            inboxItems = []
            if case .inbox = sidebarSelection { sidebarSelection = nil }
            return
        }

        inboxItems = try await InboxScanner().scanInbox(at: vaultURL)
        if case let .inbox(id) = sidebarSelection,
           !inboxItems.contains(where: { $0.id == id }) {
            sidebarSelection = nil
        }
    }

    func acceptInboxItem(_ item: InboxItem, to destinationURL: URL) async throws {
        guard let vaultURL else { return }
        let relativeDestination = try Self.vaultRelativePath(for: destinationURL, vaultURL: vaultURL)
        try await fileInboxItem(item, toRelativePath: relativeDestination, vaultURL: vaultURL)
    }

    /// Promotes an unfiled item into the vault — to the root by default, or into a
    /// known folder. The folder is purely organizational: the graph is flat, so every
    /// destination yields the same node. Resolves name collisions so the one-click
    /// path never dead-ends.
    func addToVault(_ item: InboxItem, folder: String?) async {
        guard let vaultURL else { return }
        let targetFolder = (folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = (item.path as NSString).lastPathComponent
        let destination = await uniqueRelativeDestination(
            folder: targetFolder, filename: filename, fileSystem: LocalFileSystem(root: vaultURL))
        do {
            try await fileInboxItem(item, toRelativePath: destination, vaultURL: vaultURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Shared move-out-of-Inbox flow: validate + move via `InboxAccepter`, drop the item
    /// from the in-memory inbox list (a full re-scan is async; `openVault`'s reindex re-scans
    /// shortly after), clear the selection, and reopen the vault to pick up the new document.
    private func fileInboxItem(_ item: InboxItem, toRelativePath destination: String, vaultURL: URL) async throws {
        try await InboxAccepter().accept(item, toRelativePath: destination, fileSystem: LocalFileSystem(root: vaultURL))
        inboxItems.removeAll { $0.id == item.id }
        sidebarSelection = nil
        openVault(vaultURL)
    }

    /// Maps an absolute URL chosen via the destination picker to a vault-relative path,
    /// rejecting anything outside the vault root.
    private static func vaultRelativePath(for url: URL, vaultURL: URL) throws -> String {
        let base = vaultURL.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full == base || full.hasPrefix(base + "/") else {
            throw InboxAcceptanceError.destinationOutsideVault
        }
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Creates the missing target of an unresolved HTML link as a stub document,
    /// then re-indexes and selects it. No-op for non-HTML or unresolvable targets.
    func createDocument(forUnresolved edge: LinkEdge) async {
        guard let vaultURL, let relativePath = edge.normalizedTargetPath else { return }
        let ext = (relativePath as NSString).pathExtension.lowercased()
        guard ext == "html" || ext == "htm" else { return }

        let fileSystem = LocalFileSystem(root: vaultURL)
        if !(await fileSystem.exists(at: relativePath)) {
            let filename = (relativePath as NSString).lastPathComponent
            let title = edge.linkText.isEmpty ? (filename as NSString).deletingPathExtension : edge.linkText
            do {
                try await fileSystem.createDirectory(at: (relativePath as NSString).deletingLastPathComponent)
                try await fileSystem.writeText(Self.stubHTML(title: title), to: relativePath, options: [.atomic])
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

    // MARK: - Sidebar file operations

    /// How many documents link to this one — surfaced before a rename/move/trash so the
    /// user knows how many inbound links the operation will break (the graph is the whole
    /// point of the app, so a silent break would be the worst outcome).
    func backlinkCount(forDocument id: String) -> Int {
        index?.backlinks[id]?.count ?? 0
    }

    /// Copies a document beside itself ("… copy"), then re-indexes and selects the copy.
    func duplicateDocument(_ document: DocumentNode) async {
        guard let vaultURL else { return }
        let folder = (document.path as NSString).deletingLastPathComponent
        let filename = (document.path as NSString).lastPathComponent
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let copyName = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
        let fileSystem = LocalFileSystem(root: vaultURL)
        let destination = await uniqueRelativeDestination(folder: folder, filename: copyName, fileSystem: fileSystem)
        do {
            try await fileSystem.copy(from: document.path, to: destination)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        pendingSelectionId = destination
        beginSession(at: vaultURL)
    }

    /// Moves a document into another vault folder (`nil` = root), resolving name
    /// collisions, then re-indexes and selects it at its new path.
    func moveDocument(_ document: DocumentNode, toFolder folder: String?) async {
        guard let vaultURL else { return }
        let targetFolder = (folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let currentFolder = (document.path as NSString).deletingLastPathComponent
        // Case-insensitive so a case-only "move" on a case-insensitive volume (APFS
        // default) is treated as a no-op instead of colliding with the file itself.
        guard targetFolder.localizedCaseInsensitiveCompare(currentFolder) != .orderedSame else { return }
        guard !isInboxRelativePath(targetFolder) else {
            errorMessage = "“\(InboxScanner.inboxDirectoryName)” is reserved for unfiled items."
            return
        }

        let filename = (document.path as NSString).lastPathComponent
        let fileSystem = LocalFileSystem(root: vaultURL)
        let destination = await uniqueRelativeDestination(folder: targetFolder, filename: filename, fileSystem: fileSystem)
        do {
            try await fileSystem.createDirectory(at: (destination as NSString).deletingLastPathComponent)
            try await fileSystem.move(from: document.path, to: destination)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await removeEmptyFolderIfNeeded(currentFolder, fileSystem: fileSystem)
        pendingSelectionId = destination
        beginSession(at: vaultURL)
    }

    /// Renames a document in place (folder unchanged). Forces an .html extension and
    /// strips any path components from the typed name, then re-indexes and reselects.
    func renameDocument(_ document: DocumentNode, to newName: String) async {
        guard let vaultURL else { return }
        let folder = (document.path as NSString).deletingLastPathComponent
        let originalExt = (document.path as NSString).pathExtension
        var filename = (newName as NSString).lastPathComponent
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext != "html" && ext != "htm" {
            // Preserve the document's own extension (e.g. .htm) instead of forcing .html.
            filename += originalExt.isEmpty ? ".html" : ".\(originalExt)"
        }
        guard !filename.hasPrefix(".") else {
            errorMessage = "A document name can’t start with a dot."
            return
        }
        guard filename != (document.path as NSString).lastPathComponent else { return }

        let fileSystem = LocalFileSystem(root: vaultURL)
        let destination = await uniqueRelativeDestination(folder: folder, filename: filename, fileSystem: fileSystem)
        do {
            try await fileSystem.move(from: document.path, to: destination)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        pendingSelectionId = destination
        beginSession(at: vaultURL)
    }

    /// Moves a document to the Trash (recoverable, unlike deletion), then re-indexes.
    func trashDocument(_ document: DocumentNode) async {
        guard let vaultURL else { return }
        do {
            try await LocalFileSystem(root: vaultURL).trash(at: document.path)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if sidebarSelection == .document(document.id) {
            sidebarSelection = nil
        }
        beginSession(at: vaultURL)
    }

    /// Creates a new stub document in the given vault folder (`nil` = root), then
    /// re-indexes and selects it. Reuses the same stub HTML as unresolved-link creation.
    func createDocument(inFolder folder: String?, named name: String) async {
        guard let vaultURL else { return }
        let targetFolder = (folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isInboxRelativePath(targetFolder) else {
            errorMessage = "“\(InboxScanner.inboxDirectoryName)” is reserved for unfiled items."
            return
        }
        var filename = (name as NSString).lastPathComponent
        guard !filename.isEmpty else { return }
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext != "html" && ext != "htm" {
            filename += ".html"
        }
        // A dot-leading name becomes a hidden file the indexer skips, so the new
        // document would silently never appear — reject it instead.
        guard !filename.hasPrefix(".") else {
            errorMessage = "A document name can’t start with a dot."
            return
        }
        let fileSystem = LocalFileSystem(root: vaultURL)
        let destination = await uniqueRelativeDestination(folder: targetFolder, filename: filename, fileSystem: fileSystem)
        let title = (filename as NSString).deletingPathExtension
        do {
            try await fileSystem.createDirectory(at: (destination as NSString).deletingLastPathComponent)
            try await fileSystem.writeText(Self.stubHTML(title: title), to: destination, options: [.atomic])
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        pendingSelectionId = destination
        beginSession(at: vaultURL)
    }

    /// Creates an empty folder under `parent` (`nil` = root). The tree is document-
    /// derived, so the folder is tracked in `pendingEmptyFolders` to stay visible until
    /// a document is added — no re-index needed since the document set didn't change.
    func createFolder(named name: String, inParent parent: String?) async {
        guard let vaultURL else { return }
        // Accept a typed nested path ("Reports/2024") rather than silently collapsing it
        // to the last component; clean each segment and reject dot-leading ones.
        let segments = name.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return }
        guard !segments.contains(where: { $0.hasPrefix(".") }) else {
            errorMessage = "A folder name can’t start with a dot."
            return
        }
        let trimmedParent = (parent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = segments.joined(separator: "/")
        let base = trimmedParent.isEmpty ? typed : "\(trimmedParent)/\(typed)"
        guard !isInboxRelativePath(base) else {
            errorMessage = "“\(InboxScanner.inboxDirectoryName)” is reserved for unfiled items."
            return
        }
        // Bump "name 2", "name 3", … on collision so "New Folder…" never silently merges
        // into an existing folder (matching duplicate/move/rename/createDocument).
        let fileSystem = LocalFileSystem(root: vaultURL)
        let relative = await uniqueFolderRelativePath(base, fileSystem: fileSystem)
        do {
            try await fileSystem.createDirectory(at: relative)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        pendingEmptyFolders.insert(relative)
    }

    // MARK: - In-app source editing

    /// True when the editor holds unsaved changes. Drives the unsaved-edits guard before
    /// any navigation or mutation that would tear down or leave the editor.
    var hasUnsavedEdits: Bool { editorBuffer?.isDirty ?? false }

    /// Loads a document's source from disk into the editor buffer. Reads the live file
    /// (not the index's cached title) so the editor always reflects the bytes on disk.
    /// Returns false if the document can't be read or lies outside the vault.
    @discardableResult
    func beginEditing(_ document: DocumentNode) async -> Bool {
        guard let vaultURL else { return false }
        guard let relativePath = editorRelativePath(for: document.id) else {
            errorMessage = "Cannot edit a document outside the selected vault."
            return false
        }
        let fileSystem = LocalFileSystem(root: vaultURL)
        do {
            let text = try await fileSystem.readText(at: relativePath)
            let mtime = (try? await fileSystem.metadata(at: relativePath).modificationDate) ?? .distantPast
            editorBuffer = EditorBuffer(
                documentId: document.id,
                baselineText: text,
                currentText: text,
                baselineHash: VaultIndexer.contentHash(forHTML: text),
                baselineMTime: mtime
            )
            editorConflict = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Marks the buffer as being edited through the WYSIWYG surface (called by the view after a
    /// successful `beginEditing` when entering visual mode). Its first snapshot will establish
    /// the clean reference; only while this is active are visual snapshots applied.
    func beginVisualSession() {
        visualSessionActive = true
        awaitingVisualBaseline = true
    }

    /// Mirrors live editor text into the buffer (called from the text view's binding).
    func updateEditorText(_ text: String) {
        guard editorBuffer != nil else { return }
        editorBuffer?.currentText = text
    }

    /// Mirrors the WYSIWYG editor's live DOM into the buffer as a full source document. The
    /// whole save / dirty / conflict pipeline is keyed on `editorBuffer.currentText`, so this
    /// is all the visual editor needs to plug into it: ⌘S, the unsaved-edits guard, and
    /// conflict detection then work unchanged.
    ///
    /// Preferred path: splice the edited body back into the ORIGINAL source, preserving the
    /// doctype/head/body-tag byte-for-byte. If the body region can't be located safely
    /// (implied body, or `<body>` only inside comments/scripts), fall back to the DOM's full
    /// serialization — that reformats the whole document but, crucially, NEVER drops content.
    /// Writing the bare body fragment here would silently destroy the head/doctype, so it is
    /// deliberately not a fallback.
    ///
    /// `documentId` is the editor's own document; a stale snapshot posted by an outgoing
    /// editor after the buffer has been re-baselined to a different document is ignored, so a
    /// late debounce can't corrupt the wrong file.
    func updateVisualEditedDocument(documentId: String, bodyInnerHTML: String, fullHTML: String?) {
        guard visualSessionActive, let buffer = editorBuffer, buffer.documentId == documentId else { return }
        let updated: String
        if let spliced = HTMLBodyReplacer.replacingBodyInner(of: buffer.baselineText, with: bodyInnerHTML) {
            updated = spliced
        } else if let fullHTML {
            updated = fullHTML
        } else {
            return  // no safe whole-document representation available — don't touch the file
        }
        if awaitingVisualBaseline {
            // First snapshot of this session is the unedited DOM — adopt it as the clean
            // reference so re-serialization alone never reads as an edit.
            awaitingVisualBaseline = false
            editorBuffer?.currentText = updated
            editorBuffer?.cleanText = updated
        } else if updated != buffer.currentText {
            editorBuffer?.currentText = updated
        }
    }

    /// Drops the editor buffer (and any pending conflict). Called when leaving Edit mode
    /// or after the user discards changes.
    func endEditing() {
        editorBuffer = nil
        editorConflict = nil
        visualSessionActive = false
        awaitingVisualBaseline = false
    }

    /// Resets the buffer's working text back to the last-saved baseline without leaving
    /// the editor.
    func discardEditorChanges() {
        guard let buffer = editorBuffer else { return }
        editorBuffer?.currentText = buffer.cleanText
    }

    /// Saves the editor buffer to disk and patches the index incrementally (no full
    /// reindex, so the selection and editor stay put). Returns true on a clean save;
    /// false if there was nothing to save, the write failed, or the file changed on disk
    /// (which raises `editorConflict` instead of overwriting).
    @discardableResult
    func saveEditorBuffer() async -> Bool {
        guard let buffer = editorBuffer, let vaultURL else { return false }
        guard let relativePath = editorRelativePath(for: buffer.documentId) else {
            errorMessage = "Cannot save a document outside the selected vault."
            return false
        }
        let fileSystem = LocalFileSystem(root: vaultURL)

        // Conflict pre-check: the file must still hash to the baseline we loaded. A
        // mismatch means it was changed under us (external editor, AI inbox tool, …).
        guard let diskText = try? await fileSystem.readText(at: relativePath) else {
            errorMessage = "“\(buffer.documentId)” no longer exists on disk. It may have been moved or deleted."
            return false
        }
        let diskHash = VaultIndexer.contentHash(forHTML: diskText)
        if diskHash != buffer.baselineHash {
            let diskMTime = (try? await fileSystem.metadata(at: relativePath).modificationDate) ?? Date()
            editorConflict = EditorConflict(
                documentId: buffer.documentId,
                pendingText: buffer.currentText,
                diskText: diskText,
                diskHash: diskHash,
                diskMTime: diskMTime
            )
            return false
        }

        return await writeEditorText(buffer.currentText, toRelativePath: relativePath, documentId: buffer.documentId, fileSystem: fileSystem)
    }

    /// Conflict resolution: write the user's unsaved text over the changed file.
    func resolveConflictByOverwriting() async {
        guard let conflict = editorConflict, let vaultURL,
              let relativePath = editorRelativePath(for: conflict.documentId) else {
            editorConflict = nil
            return
        }
        editorConflict = nil
        _ = await writeEditorText(
            conflict.pendingText, toRelativePath: relativePath, documentId: conflict.documentId,
            fileSystem: LocalFileSystem(root: vaultURL))
    }

    /// Conflict resolution: discard the user's unsaved text and reload the disk version
    /// as the new baseline.
    func resolveConflictByReloading() {
        guard let conflict = editorConflict else { return }
        editorBuffer = EditorBuffer(
            documentId: conflict.documentId,
            baselineText: conflict.diskText,
            currentText: conflict.diskText,
            baselineHash: conflict.diskHash,
            baselineMTime: conflict.diskMTime
        )
        editorConflict = nil
        // The source editor follows its text binding, but the visual editor renders from a
        // one-shot web view load — force it to rebuild so it shows the adopted disk version,
        // and let its first snapshot re-establish the clean reference.
        awaitingVisualBaseline = true
        visualReloadToken = UUID()
    }

    func dismissConflict() {
        editorConflict = nil
    }

    /// Writes `text` atomically, then patches the index in place for just this document.
    /// Deliberately avoids `beginSession` so the selection, scroll, and editor survive.
    @discardableResult
    private func writeEditorText(_ text: String, toRelativePath relativePath: String, documentId: String, fileSystem: VaultFileSystem) async -> Bool {
        guard let vaultURL else { return false }
        do {
            try await fileSystem.writeText(text, to: relativePath, options: [.atomic])
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        // Invalidate any in-flight full reindex so its stale result can't overwrite this
        // incremental patch when it lands (finishIndexing is gated on this generation).
        indexingGeneration = UUID()

        if let index {
            do {
                let patched = try await VaultIndexer().reindexDocument(index, changedRelativePath: documentId, fileSystem: fileSystem)
                self.index = patched
                // Keep the AI sidecar current; a failure must not break the save.
                Task {
                    do {
                        try await VaultIndexExporter().export(patched, fileSystem: fileSystem)
                    } catch {
                        Self.exportLogger.error("graph.json export failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                // Re-embed just this document, off-main, after the reindex returned. Never
                // gates save success — only the embedding is async and strictly downstream.
                refreshEmbedding(forDocumentId: documentId, in: patched, vaultURL: vaultURL)
            } catch {
                // The write already succeeded, so no data is lost; only the in-memory
                // graph is briefly stale until the next full reindex reconciles it.
                Self.exportLogger.error("incremental reindex failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let mtime = (try? await fileSystem.metadata(at: relativePath).modificationDate) ?? Date()
        // The write/reindex above suspended the main actor, so the user may have typed more
        // into the SAME document during the await window. Adopt the written bytes as the new
        // clean baseline, but KEEP the live `currentText` so those intervening edits aren't
        // silently discarded (they stay dirty and save on the next ⌘S). Guard on documentId so
        // a buffer re-baselined to a different document mid-await isn't clobbered.
        if editorBuffer?.documentId == documentId {
            editorBuffer = EditorBuffer(
                documentId: documentId,
                baselineText: text,
                currentText: editorBuffer?.currentText ?? text,
                baselineHash: VaultIndexer.contentHash(forHTML: text),
                baselineMTime: mtime
            )
        }
        editorConflict = nil
        return true
    }

    /// Validates a document id as an editable vault-relative path, rejecting path escapes
    /// (mirrors the loopback server's containment check). Returns the id when safe.
    private func editorRelativePath(for id: String) -> String? {
        guard !id.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
        return id
    }

    /// Moves an unfiled inbox item to the Trash and refreshes the inbox.
    func trashInboxItem(_ item: InboxItem) async {
        guard let vaultURL else { return }
        do {
            try await LocalFileSystem(root: vaultURL).trash(at: item.path)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if sidebarSelection == .inbox(item.id) {
            sidebarSelection = nil
        }
        // The item is in the Trash now; drop it from the in-memory list (a re-scan is async).
        inboxItems.removeAll { $0.id == item.id }
    }

    /// True for the vault's reserved Inbox dropbox (or anything inside it). The indexer
    /// excludes these paths from the graph, so the sidebar must never offer them as a
    /// create/move destination — a document landing there silently becomes "Unfiled".
    private func isInboxRelativePath(_ relativePath: String) -> Bool {
        // Case-insensitive: on a case-insensitive volume (APFS default) a folder typed as
        // "inbox"/"INBOX" still resolves to the reserved Inbox dir, so it must be guarded
        // too — otherwise a document placed there is silently excluded from the graph.
        let inbox = InboxScanner.inboxDirectoryName.lowercased()
        let path = relativePath.lowercased()
        return path == inbox || path.hasPrefix(inbox + "/")
    }

    /// Returns `base` (vault-relative) bumped to "base 2", "base 3", … until it names a
    /// path that doesn't yet exist on disk, so folder creation never merges into an
    /// existing directory.
    private func uniqueFolderRelativePath(_ base: String, fileSystem: VaultFileSystem) async -> String {
        var candidate = base
        var suffix = 2
        while await fileSystem.exists(at: candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// Removes a now-empty source folder after a move so the sidebar (which is derived
    /// from documents) and Finder don't drift apart. Conservative: never touches the
    /// vault root, the Inbox, or a folder that still holds anything (incl. hidden files).
    private func removeEmptyFolderIfNeeded(_ relativeFolder: String, fileSystem: VaultFileSystem) async {
        guard !relativeFolder.isEmpty, !isInboxRelativePath(relativeFolder) else { return }
        guard let contents = try? await fileSystem.contentsOfDirectory(at: relativeFolder),
              contents.isEmpty else { return }
        try? await fileSystem.remove(at: relativeFolder)
        pendingEmptyFolders.remove(relativeFolder)
    }

    /// Builds a non-colliding destination for a file going into `folder` (vault-relative,
    /// "" = root), returning both the absolute URL and the matching relative path (which
    /// is also the document's index id). Bumps "name 2", "name 3", … on collision.
    private func uniqueRelativeDestination(folder: String, filename: String, fileSystem: VaultFileSystem) async -> String {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        func relativePath(_ name: String) -> String {
            folder.isEmpty ? name : "\(folder)/\(name)"
        }

        var name = filename
        var suffix = 2
        while await fileSystem.exists(at: relativePath(name)) {
            name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            suffix += 1
        }
        return relativePath(name)
    }

    private func startInboxPolling() {
        inboxPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    try await self?.refreshInbox()
                } catch is CancellationError {
                    return
                } catch {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
