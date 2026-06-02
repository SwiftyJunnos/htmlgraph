import HTMLGraphCore
import SwiftUI

struct ContextPane: View {
    @EnvironmentObject private var appState: AppState
    @State private var tab: ContextTab = .backlinks

    private enum ContextTab: String, CaseIterable, Identifiable {
        case backlinks = "Backlinks"
        case unresolved = "Unresolved"
        case localGraph = "Local Graph"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Context", selection: $tab) {
                ForEach(ContextTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            Group {
                switch tab {
                case .backlinks:
                    backlinksView
                case .unresolved:
                    unresolvedLinksView
                case .localGraph:
                    localGraphView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var backlinksView: some View {
        if appState.index == nil {
            noVaultState
        } else if appState.selectedDocumentId == nil {
            noSelectionState
        } else if backlinks.isEmpty {
            ContentUnavailableView(
                "No backlinks",
                systemImage: "arrow.left",
                description: Text("No other document links to this one.")
            )
        } else {
            List(backlinks) { edge in
                Button {
                    appState.selectDocument(edge.sourceId)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(documentTitle(for: edge.sourceId))
                                .lineLimit(1)
                            if !edge.linkText.isEmpty {
                                Text(edge.linkText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go to “\(documentTitle(for: edge.sourceId))”")
            }
        }
    }

    private func documentTitle(for id: String) -> String {
        appState.index?.document(id: id)?.title ?? id
    }

    @ViewBuilder
    private var unresolvedLinksView: some View {
        if appState.index == nil {
            noVaultState
        } else if appState.selectedDocumentId == nil {
            noSelectionState
        } else if unresolvedLinks.isEmpty {
            ContentUnavailableView(
                "No unresolved links",
                systemImage: "link",
                description: Text("Every link in this document points to a known file.")
            )
        } else {
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
            noVaultState
        }
    }

    private var noVaultState: some View {
        ContentUnavailableView(
            "No vault open",
            systemImage: "folder",
            description: Text("Open a local HTML vault to view document links.")
        )
    }

    private var noSelectionState: some View {
        ContentUnavailableView(
            "No document selected",
            systemImage: "doc.text",
            description: Text("Select a document to see its links.")
        )
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
