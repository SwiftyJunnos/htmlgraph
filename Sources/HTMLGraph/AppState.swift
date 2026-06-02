import Foundation
import HTMLGraphCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var vaultURL: URL?
    @Published var index: VaultIndex?
    @Published var selectedDocumentId: String?
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
    @Published var selectedInboxItemId: String?

    private var indexingTask: Task<Void, Never>?
    private var inboxPollingTask: Task<Void, Never>?
    private var indexingGeneration = UUID()

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
        selectedDocumentId = nil
        selectedInboxItemId = nil
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
            selectedDocumentId = builtIndex.documents.first?.id
            if let vaultURL {
                inboxItems = (try? InboxScanner().scanInbox(at: vaultURL)) ?? inboxItems
            }
            errorMessage = nil
        case .failure(let error):
            index = nil
            selectedDocumentId = nil
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
        selectedDocumentId = id
        selectedInboxItemId = nil
    }

    func selectInboxItem(_ id: String) {
        selectedInboxItemId = id
        selectedDocumentId = nil
    }

    func refreshInbox() throws {
        guard let vaultURL else {
            inboxItems = []
            selectedInboxItemId = nil
            return
        }

        inboxItems = try InboxScanner().scanInbox(at: vaultURL)
        if let selectedInboxItemId,
           !inboxItems.contains(where: { $0.id == selectedInboxItemId }) {
            self.selectedInboxItemId = nil
        }
    }

    func acceptInboxItem(_ item: InboxItem, to destinationURL: URL) throws {
        guard let vaultURL else { return }

        try InboxAccepter().accept(item, to: destinationURL, vaultURL: vaultURL)
        try refreshInbox()
        selectedInboxItemId = nil
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
