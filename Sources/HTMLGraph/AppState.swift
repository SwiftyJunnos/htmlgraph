import Foundation
import HTMLGraphCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var vaultURL: URL?
    @Published var index: VaultIndex?
    @Published var selectedDocumentId: String?
    @Published var searchText = ""
    @Published var trustMode: VaultTrustMode = .safe
    @Published var allowsNetworkAccess = false
    @Published var errorMessage: String?

    var selectedDocument: DocumentNode? {
        guard let selectedDocumentId else { return nil }
        return index?.document(id: selectedDocumentId)
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
        do {
            let builtIndex = try VaultIndexer().indexVault(at: url)
            vaultURL = url
            index = builtIndex
            selectedDocumentId = builtIndex.documents.first?.id
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectDocument(_ id: String) {
        selectedDocumentId = id
    }
}
