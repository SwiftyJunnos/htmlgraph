import HTMLGraphCore
import SwiftUI

struct VaultSidebar: View {
    @EnvironmentObject private var appState: AppState

    /// A single selection type so Inbox and Documents share one `List` selection,
    /// giving uniform highlight and keyboard navigation across both sections.
    private enum SidebarItemID: Hashable {
        case inbox(String)
        case document(String)
    }

    var body: some View {
        List(selection: selection) {
            if !appState.inboxItems.isEmpty {
                Section {
                    ForEach(appState.inboxItems) { item in
                        row(title: item.title, subtitle: item.path)
                            .tag(SidebarItemID.inbox(item.id))
                    }
                } header: {
                    HStack {
                        Text("Inbox")
                        Spacer()
                        Text("\(appState.inboxItems.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            if !appState.filteredDocuments.isEmpty {
                Section("Documents") {
                    ForEach(appState.filteredDocuments) { document in
                        row(title: document.title, subtitle: document.path)
                            .tag(SidebarItemID.document(document.id))
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

    private var selection: Binding<SidebarItemID?> {
        Binding(
            get: {
                if let id = appState.selectedInboxItemId {
                    return .inbox(id)
                }
                if let id = appState.selectedDocumentId {
                    return .document(id)
                }
                return nil
            },
            set: { newValue in
                switch newValue {
                case let .inbox(id):
                    appState.selectInboxItem(id)
                case let .document(id):
                    appState.selectDocument(id)
                case nil:
                    break
                }
            }
        )
    }
}
