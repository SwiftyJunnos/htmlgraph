import SwiftUI

struct VaultSidebar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search files", text: $appState.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 10)

            List(appState.filteredDocuments, selection: $appState.selectedDocumentId) { document in
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(document.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(document.id)
            }
        }
    }
}
