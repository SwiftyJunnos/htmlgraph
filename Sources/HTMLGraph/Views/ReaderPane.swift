import SwiftUI

struct ReaderPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document = appState.selectedDocument {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(document.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(appState.trustMode == .safe ? "Safe Mode" : "Trusted Mode")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button("Open External") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: document.absolutePath))
                    }
                }
                .padding()

                Divider()

                Text("Selected file: \(document.absolutePath)")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Open a vault",
                    systemImage: "folder",
                    description: Text("Choose a local HTML folder to begin.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
