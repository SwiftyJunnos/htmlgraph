import SwiftUI

/// The "Connect to Remote…" sheet: gathers SSH/SFTP connection details and opens the remote
/// vault. Password-only auth for now (key auth + Keychain persistence + host-key TOFU are
/// hardening follow-ups); the password lives only in the live connection for this session.
struct RemoteConnectView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var remotePath = ""

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !remotePath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Remote Vault")
                .font(.headline)
            Text("Open an HTMLGraph vault on a remote host over SSH/SFTP. Documents, search, and "
                + "the preview all work over the connection.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Host", text: $host, prompt: Text("example.com"))
                TextField("Port", text: $port, prompt: Text("22"))
                TextField("Username", text: $username, prompt: Text("user"))
                SecureField("Password", text: $password)
                TextField("Vault path", text: $remotePath, prompt: Text("/home/user/vault"))
            }
            .textFieldStyle(.roundedBorder)

            Text("The password is saved to your Keychain so you can reopen this vault from Recent.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func connect() {
        appState.openRemoteVault(
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port.trimmingCharacters(in: .whitespaces)) ?? 22,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            remotePath: remotePath.trimmingCharacters(in: .whitespaces)
        )
        dismiss()
    }
}
