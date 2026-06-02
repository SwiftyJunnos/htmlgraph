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

    private var indexingTask: Task<Void, Never>?
    private var inboxPollingTask: Task<Void, Never>?
    private var indexingGeneration = UUID()

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

    func openVault(_ url: URL) {
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

    private func finishIndexing(generation: UUID, result: Result<VaultIndex, Error>) {
        guard generation == indexingGeneration else { return }

        isIndexing = false
        indexingTask = nil

        switch result {
        case .success(let builtIndex):
            index = builtIndex
            sidebarSelection = builtIndex.documents.first.map { .document($0.id) }
            if let vaultURL {
                inboxItems = (try? InboxScanner().scanInbox(at: vaultURL)) ?? inboxItems
            }
            errorMessage = nil
        case .failure(let error):
            index = nil
            sidebarSelection = nil
            errorMessage = error.localizedDescription
        }
    }

    private func finishCancelledIndexing(generation: UUID) {
        guard generation == indexingGeneration else { return }
        isIndexing = false
        indexingTask = nil
    }

    deinit {
        indexingTask?.cancel()
        inboxPollingTask?.cancel()
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
