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

    private var indexingTask: Task<Void, Never>?
    private var indexingGeneration = UUID()

    var selectedDocument: DocumentNode? {
        guard let selectedDocumentId else { return nil }
        return index?.document(id: selectedDocumentId)
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

        let generation = UUID()
        indexingGeneration = generation
        vaultURL = url
        index = nil
        selectedDocumentId = nil
        errorMessage = nil
        isIndexing = true

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
    }

    private func finishIndexing(generation: UUID, result: Result<VaultIndex, Error>) {
        guard generation == indexingGeneration else { return }

        isIndexing = false
        indexingTask = nil

        switch result {
        case .success(let builtIndex):
            index = builtIndex
            selectedDocumentId = builtIndex.documents.first?.id
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
    }

    func selectDocument(_ id: String) {
        selectedDocumentId = id
    }
}
