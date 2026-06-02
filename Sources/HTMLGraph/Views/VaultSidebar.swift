import HTMLGraphCore
import SwiftUI

struct VaultSidebar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List(selection: $appState.sidebarSelection) {
            if !appState.inboxItems.isEmpty {
                Section {
                    ForEach(appState.inboxItems) { item in
                        row(title: item.title, subtitle: item.path)
                            .tag(SidebarSelection.inbox(item.id))
                    }
                } header: {
                    Text("Unfiled")
                }
                .badge(appState.inboxItems.count)
            }

            if !appState.filteredDocuments.isEmpty {
                Section("Documents") {
                    ForEach(appState.filteredDocuments) { document in
                        row(title: document.title, subtitle: document.path)
                            .tag(SidebarSelection.document(document.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(title: String, subtitle: String) -> some View {
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
