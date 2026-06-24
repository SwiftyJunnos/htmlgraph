import HTMLGraphCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsSecurityPopover = false
    @State private var showsGitHubPagesDeploySheet = false
    @AppStorage("showsContextPanel") private var showsContextPanel = true

    var body: some View {
        NavigationSplitView {
            VaultSidebar()
                .searchable(text: $appState.searchText, placement: .sidebar, prompt: "Search documents")
                // Lexical (title) and semantic (meaning) search now run together and render as
                // two sidebar sections, so there's no Title/Meaning scope toggle. Re-run the
                // semantic pass on every query change (debounced + generation-guarded inside
                // AppState; clears itself for an empty query).
                .onChange(of: appState.searchText) { _, _ in appState.runSemanticSearch() }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            ReaderPane {
                chooseVault()
            } onAcceptInboxItem: { item in
                acceptInboxItem(item)
            }
            // The context panel (backlinks / unresolved / local graph) lives in a native
            // inspector so it gets the same collapse/expand affordance the leading sidebar
            // has; the toolbar button below toggles it and the binding is persisted across
            // launches. Attach it to the detail, NOT the whole NavigationSplitView:
            // attaching at the split-view level makes the leading sidebar clip and shift
            // off-screen (and the inspector's own overlays drop) once the inspector is
            // dragged to a large width. On the detail it stays a trailing pane and leaves
            // the sidebar layout untouched.
            .inspector(isPresented: $showsContextPanel) {
                ContextPane()
                    .inspectorColumnWidth(min: 220, ideal: 280, max: 720)
            }
        }
        .navigationTitle(appState.vaultDisplayName ?? "HTMLGraph")
        .navigationSubtitle(appState.vaultStatusText)
        .sheet(isPresented: $appState.isShowingRemoteConnect) {
            RemoteConnectView()
                .environmentObject(appState)
        }
        .toolbar {
            if appState.hasOpenVault {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showsSecurityPopover = true
                    } label: {
                        Label(
                            appState.trustMode == .trusted ? "Trusted" : "Safe",
                            systemImage: appState.trustMode == .trusted ? "lock.shield.fill" : "lock.shield"
                        )
                    }
                    .help("Document rendering security — JavaScript and network access.")
                    .popover(isPresented: $showsSecurityPopover, arrowEdge: .bottom) {
                        SecuritySettingsView()
                    }
                }

                // Reliable entry point for vault-root creation — the sidebar's empty-space
                // context menu is not dependable on macOS, so these also live in the toolbar.
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("New Document…") { SidebarActions.newDocument(inFolder: nil, appState: appState) }
                        Button("New Folder…") { SidebarActions.newFolder(inParent: nil, appState: appState) }
                        Divider()
                        Button("Export Web Site…") { exportWebSite() }
                        Button("Deploy to GitHub Pages…") { showsGitHubPagesDeploySheet = true }
                            .disabled(appState.isDeployingStaticSite)
                        Button("Reveal Vault in Finder") {
                            if let path = appState.vaultURL?.path { SidebarCommands.reveal(absolutePath: path) }
                        }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .help("Create a new document or folder at the vault root.")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        chooseVault()
                    } label: {
                        Label(appState.openVaultButtonTitle, systemImage: appState.openVaultSymbolName)
                    }
                    .help("Choose a different local HTML folder to open as a vault.")
                }
            }

            // Trailing toggle for the context inspector — mirrors the leading sidebar
            // toggle macOS provides automatically. Always available so the panel can be
            // hidden even before a vault is open.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsContextPanel.toggle()
                } label: {
                    Label("Context Panel", systemImage: "sidebar.right")
                }
                .help("Show or hide the context panel — backlinks, unresolved links, and the local graph.")
            }
        }
        .alert("HTMLGraph Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    appState.errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .alert("Web Site Exported", isPresented: Binding(
            get: { appState.exportedSiteURL != nil },
            set: { isPresented in
                if !isPresented {
                    appState.exportedSiteURL = nil
                }
            }
        )) {
            Button("Reveal") {
                if let path = appState.exportedSiteURL?.path {
                    SidebarCommands.reveal(absolutePath: path)
                }
                appState.exportedSiteURL = nil
            }
            Button("OK", role: .cancel) {
                appState.exportedSiteURL = nil
            }
        } message: {
            Text("Upload this folder to a static host such as GitHub Pages, Netlify, or S3.")
        }
        .alert("GitHub Pages Deployed", isPresented: Binding(
            get: { appState.deployedSiteURL != nil },
            set: { isPresented in
                if !isPresented {
                    appState.deployedSiteURL = nil
                }
            }
        )) {
            Button("Copy URL") {
                if let url = appState.deployedSiteURL {
                    SidebarCommands.copyToPasteboard(url.absoluteString)
                }
                appState.deployedSiteURL = nil
            }
            Button("OK", role: .cancel) {
                appState.deployedSiteURL = nil
            }
        } message: {
            Text(appState.deployedSiteURL?.absoluteString ?? "")
        }
        .sheet(isPresented: $showsGitHubPagesDeploySheet) {
            GitHubPagesDeploySheet()
                .environmentObject(appState)
        }
    }

    private func chooseVault() {
        Task {
            guard await EditorGuard.confirmLeavingEditor(appState) else { return }
            appState.chooseAndOpenVault()
        }
    }

    private func exportWebSite() {
        Task {
            // `confirmLeavingEditor` is async (it may save over the network), so confirm first,
            // then run the local export-folder picker and kick off the export.
            guard await EditorGuard.confirmLeavingEditor(appState),
                  let destinationURL = VaultFolderPicker.chooseStaticSiteExportFolder() else {
                return
            }
            appState.exportStaticSite(to: destinationURL)
        }
    }

    private func acceptInboxItem(_ item: InboxItem) {
        Task {
            // Accepting reopens the vault (a full reindex that clears the editor buffer), so
            // confirm any unsaved edits before the destination picker takes over.
            guard await EditorGuard.confirmLeavingEditor(appState) else { return }
            guard let vaultURL = appState.vaultURL,
                  let destinationURL = InboxDestinationPicker.chooseDestination(for: item, vaultURL: vaultURL) else {
                return
            }
            do {
                try await appState.acceptInboxItem(item, to: destinationURL)
            } catch {
                appState.errorMessage = error.localizedDescription
            }
        }
    }
}

/// Per-vault rendering-security controls, shown in a toolbar popover where each option
/// can carry an explanation. The chosen trust/network posture is remembered per vault
/// (see `AppState`) and restored when that vault is reopened.
private struct SecuritySettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Trust")
                    .font(.headline)
                Picker("Trust", selection: $appState.trustMode) {
                    Text("Safe").tag(VaultTrustMode.safe)
                    Text("Trusted").tag(VaultTrustMode.trusted)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Safe renders documents statically. Trusted lets a document run JavaScript — use it only for documents you trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Allow network access", isOn: $appState.allowsNetworkAccess)
                    .disabled(appState.trustMode != .trusted)
                Text("Lets documents load remote resources and connect out. Requires Trusted mode, so enabling it also lets documents run JavaScript. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct GitHubPagesDeploySheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var selectedRepository = ""
    @State private var owner = ""
    @State private var repo = ""
    @State private var branch = "gh-pages"
    @State private var token = ""

    private var canConnectGitHub: Bool {
        appState.isGitHubOAuthConfigured && !appState.isConnectingGitHub
    }

    private var hasDeploymentAuth: Bool {
        appState.hasGitHubOAuthToken || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedGitHubRepository: GitHubRepository? {
        appState.githubRepositories.first { $0.fullName == selectedRepository }
    }

    private var usesTokenFallback: Bool {
        !appState.isGitHubOAuthConfigured
    }

    private var canDeploy: Bool {
        let hasRepository = usesTokenFallback
            ? !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : selectedGitHubRepository != nil

        return hasRepository &&
            !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            hasDeploymentAuth &&
            !appState.isDeployingStaticSite
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Deploy to GitHub Pages")
                .font(.headline)

            HStack(spacing: 10) {
                if appState.hasGitHubOAuthToken {
                    Label("GitHub connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Disconnect") { appState.disconnectGitHub() }
                } else if appState.isConnectingGitHub {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for GitHub")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { appState.cancelGitHubDeviceFlow() }
                } else if appState.isGitHubOAuthConfigured {
                    Button("Sign in to GitHub") {
                        appState.startGitHubDeviceFlow()
                    }
                    .disabled(!canConnectGitHub)
                } else {
                    Text("GitHub sign-in is not available in this build. Use a token below.")
                        .foregroundStyle(.secondary)
                }
            }

            if let code = appState.githubDeviceCode {
                HStack(spacing: 12) {
                    Text(code.userCode)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                    Button("Open GitHub") { openURL(code.verificationURI) }
                }
            }

            Divider()

            if appState.hasGitHubOAuthToken {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Repository")
                        if appState.isLoadingGitHubRepositories {
                            ProgressView("Loading repositories…")
                        } else if appState.githubRepositories.isEmpty {
                            Text("No writable repositories found.")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Repository", selection: $selectedRepository) {
                                Text("Choose repository").tag("")
                                ForEach(appState.githubRepositories) { repository in
                                    Text(repository.fullName).tag(repository.fullName)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    GridRow {
                        Text("Branch")
                        TextField("gh-pages", text: $branch)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(appState.isDeployingStaticSite)
            } else if !appState.isGitHubOAuthConfigured {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Owner")
                        TextField("octocat", text: $owner)
                    }
                    GridRow {
                        Text("Repository")
                        TextField("my-vault", text: $repo)
                    }
                    GridRow {
                        Text("Branch")
                        TextField("gh-pages", text: $branch)
                    }
                    GridRow {
                        Text("Token")
                        SecureField("Personal access token", text: $token)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(appState.isDeployingStaticSite)
            }

            if appState.isDeployingStaticSite {
                ProgressView("Deploying…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(appState.isDeployingStaticSite)
                Button("Deploy") {
                    if let repository = selectedGitHubRepository {
                        appState.deployStaticSiteToGitHubPages(owner: repository.owner, repo: repository.name, branch: branch)
                    } else {
                        appState.deployStaticSiteToGitHubPages(
                            config: GitHubPagesDeploymentConfig(
                                owner: owner,
                                repo: repo,
                                branch: branch,
                                token: token
                            )
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canDeploy)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear {
            if appState.hasGitHubOAuthToken, appState.githubRepositories.isEmpty {
                appState.refreshGitHubRepositories()
            }
        }
        .onChange(of: appState.githubDeviceCode) { _, code in
            if let code { openURL(code.verificationURI) }
        }
        .onChange(of: appState.hasGitHubOAuthToken) { _, connected in
            if !connected {
                selectedRepository = ""
            }
        }
        .onChange(of: appState.githubRepositories) { _, repositories in
            if selectedRepository.isEmpty {
                selectedRepository = repositories.first?.fullName ?? ""
            }
        }
        .onDisappear {
            appState.cancelGitHubDeviceFlow()
        }
        .onChange(of: appState.deployedSiteURL) { _, url in
            if url != nil { dismiss() }
        }
    }
}
