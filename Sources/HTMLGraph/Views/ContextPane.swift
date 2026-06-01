import HTMLGraphCore
import SwiftUI

struct ContextPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            backlinksView
                .tabItem { Text("Backlinks") }
            unresolvedLinksView
                .tabItem { Text("Unresolved") }
            localGraphView
                .tabItem { Text("Local Graph") }
        }
    }

    private var backlinksView: some View {
        List(backlinks) { edge in
            VStack(alignment: .leading, spacing: 3) {
                Text(edge.sourceId)
                    .lineLimit(1)
                Text(edge.linkText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var unresolvedLinksView: some View {
        List(unresolvedLinks) { edge in
            VStack(alignment: .leading, spacing: 3) {
                Text(edge.href)
                    .lineLimit(1)
                Text(edge.linkText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var localGraphView: some View {
        if let index = appState.index {
            GraphWebView(
                centerId: appState.selectedDocumentId,
                index: index,
                global: false,
                onSelect: { id in
                    appState.selectDocument(id)
                }
            )
        } else {
            ContentUnavailableView(
                "No vault open",
                systemImage: "folder",
                description: Text("Open a local HTML vault to view document links.")
            )
        }
    }

    private var backlinks: [LinkEdge] {
        guard let selectedDocumentId = appState.selectedDocumentId else { return [] }
        return appState.index?.backlinks[selectedDocumentId] ?? []
    }

    private var unresolvedLinks: [LinkEdge] {
        guard let selectedDocumentId = appState.selectedDocumentId else { return [] }
        return appState.index?.unresolvedLinks[selectedDocumentId] ?? []
    }
}
