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
            Text("Local graph is added in Task 8")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var backlinks: [LinkEdge] {
        guard let selectedDocumentId = appState.selectedDocumentId else { return [] }
        return appState.index?.backlinks[selectedDocumentId] ?? []
    }

    private var unresolvedLinks: [LinkEdge] {
        guard let selectedDocumentId = appState.selectedDocumentId else { return [] }
        return appState.index?.unresolvedLinks[selectedDocumentId] ?? []
    }
}
