import SwiftUI

struct GlobalGraphView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let index = appState.index {
            GraphWebView(
                centerId: appState.selectedDocumentId,
                index: index,
                global: true,
                onSelect: { id in
                    appState.selectDocument(id)
                }
            )
            .frame(minWidth: 760, minHeight: 560)
        } else {
            ContentUnavailableView(
                "No vault open",
                systemImage: "folder",
                description: Text("Open a local HTML vault to view the global graph.")
            )
            .frame(minWidth: 760, minHeight: 560)
        }
    }
}
