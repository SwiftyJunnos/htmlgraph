import AppKit
import Sparkle
import SwiftUI

@main
struct HTMLGraphApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage("autoReopenLastVault") private var autoReopenLastVault = true
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1100, minHeight: 720)
                .task {
                    // Wire the app-state into the delegate so the quit guard can inspect
                    // unsaved editor edits before the process terminates.
                    appDelegate.appState = appState
                    if autoReopenLastVault,
                       appState.vaultURL == nil,
                       let mostRecent = appState.recentVaults.first {
                        appState.openRecent(mostRecent, isAutomatic: true)
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterController.checkForUpdates(nil)
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("Open Vault...") {
                    guard EditorGuard.confirmLeavingEditor(appState) else { return }
                    appState.chooseAndOpenVault()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Global Graph") {
                    openWindow(id: "global-graph")
                }
                .keyboardShortcut("g", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Menu("Open Recent") {
                    ForEach(appState.recentVaults) { recent in
                        Button(recent.displayName) {
                            guard EditorGuard.confirmLeavingEditor(appState) else { return }
                            appState.openRecent(recent)
                        }
                    }
                    if !appState.recentVaults.isEmpty {
                        Divider()
                        Button("Clear Menu") {
                            appState.clearRecents()
                        }
                    }
                }
                .disabled(appState.recentVaults.isEmpty)

                Toggle("Reopen Last Vault on Launch", isOn: $autoReopenLastVault)

                Divider()

                // Regenerate the vault's AGENTS.md / CLAUDE.md from the current template.
                // Created automatically (create-only) on open; this is the deliberate
                // refresh, so it confirms first — the rewrite clobbers any manual edits.
                Button("Regenerate Agent Guide…") {
                    let alert = NSAlert()
                    alert.messageText = "Regenerate AGENTS.md and CLAUDE.md?"
                    alert.informativeText = "This rewrites the agent-guide files at the vault root with HTMLGraph’s current template. Any manual edits to them will be lost."
                    alert.addButton(withTitle: "Regenerate")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    appState.regenerateAgentGuide()
                }
                .disabled(appState.vaultURL == nil)
            }
        }

        Window("Global Graph", id: "global-graph") {
            GlobalGraphView()
                .environmentObject(appState)
        }
    }
}

/// Hosts the only process-exit hook SwiftUI doesn't surface declaratively: a quit guard
/// that gives the in-app editor a chance to flush or discard unsaved edits before the
/// app terminates. `appState` is injected from the `WindowGroup`'s `.task`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        // The delegate is always called on the main thread; AppState is @MainActor.
        return MainActor.assumeIsolated {
            EditorGuard.confirmLeavingEditor(appState) ? .terminateNow : .terminateCancel
        }
    }
}
