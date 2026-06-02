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
/// documents render as selectable rows.
private struct DocumentTreeRows: View {
    let nodes: [DocumentTreeNode]
    @Binding var collapsedFolders: Set<String>

    var body: some View {
        ForEach(nodes) { node in
            if let document = node.document {
                SidebarRowLabel(title: document.title, subtitle: node.name)
                    .tag(SidebarSelection.document(document.id))
            } else {
                DisclosureGroup(isExpanded: expansion(for: node.id)) {
                    DocumentTreeRows(nodes: node.children, collapsedFolders: $collapsedFolders)
                } label: {
                    Label(node.name, systemImage: "folder")
                }
            }
        }
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
