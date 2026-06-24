import Citadel
import Foundation
import NIOCore

/// A credential for an SFTP connection. Sendable raw material — the (non-Sendable)
/// `SSHAuthenticationMethod` is built fresh at connect time, never stored.
public enum SFTPCredential: Sendable {
    case password(String)
    // TODO (hardening): key-based auth (.ed25519 / .rsa) once the OpenSSH key-parsing API is
    // pinned down — Citadel's SSHAuthenticationMethod supports it; the credential just needs a
    // Sendable representation of the private key.
}

/// A `VaultFileSystem` backed by a remote host over SSH/SFTP (via Citadel). Every path is
/// vault-relative and joined under the remote vault root; reads/writes/metadata go over the
/// wire. A single `SFTPConnection` actor owns the live `SFTPClient` and is shared across
/// operations so the connection is reused.
///
/// First-cut limitations (tracked for hardening): atomic writes are temp-write + remove +
/// rename (a brief non-atomic window, since plain SFTP rename can't overwrite); no metadata
/// cache; concurrent first-use can briefly open two connections.
public struct SFTPFileSystem: VaultFileSystem {
    public let vaultIdentity: String
    public let displayName: String
    public let displaySubtitle: String?
    /// Normalized absolute remote root (no trailing slash, never empty).
    private let root: String
    private let connection: SFTPConnection

    public init(host: String, port: Int = 22, username: String, credential: SFTPCredential, remotePath: String) {
        let root = Self.normalizeRoot(remotePath)
        self.root = root
        self.vaultIdentity = "sftp://\(username)@\(host):\(port)\(root)"
        // The window title shows the remote folder name (host when the root is "/"); the
        // subtitle shows where it lives, omitting the default SSH port.
        let lastComponent = (root as NSString).lastPathComponent
        self.displayName = (lastComponent.isEmpty || lastComponent == "/") ? host : lastComponent
        let hostPort = port == 22 ? host : "\(host):\(port)"
        self.displaySubtitle = "\(username)@\(hostPort):\(root)"
        self.connection = SFTPConnection(host: host, port: port, username: username, credential: credential)
    }

    /// Remote/SSH vaults have no local on-disk path.
    public func absolutePath(for relativePath: String) -> String? { nil }

    /// Closes the live SSH/SFTP connection. Call when switching away from this vault so SSH
    /// sessions don't leak across opens. Safe to call when never connected (a no-op).
    public func disconnect() async {
        await connection.disconnect()
    }

    // MARK: - Enumeration

    public func enumerateFiles(under subpath: String) async throws -> [VaultFileEntry] {
        let client = try await connection.client()
        var entries: [VaultFileEntry] = []
        var stack = [trim(subpath)]
        while let dir = stack.popLast() {
            // A missing directory yields nothing (matches LocalFileSystem's nil-enumerator).
            guard let listing = try? await client.listDirectory(atPath: remotePath(dir)) else { continue }
            for component in listing.flatMap(\.components) {
                let name = component.filename
                // Skip "." / ".." and hidden entries (mirrors `.skipsHiddenFiles`).
                if name == "." || name == ".." || name.hasPrefix(".") { continue }
                let relative = dir.isEmpty ? name : "\(dir)/\(name)"
                let attributes = component.attributes
                if Self.isDirectory(attributes) {
                    stack.append(relative)
                } else if Self.isRegularFile(attributes) {
                    entries.append(VaultFileEntry(
                        relativePath: relative,
                        size: Int(attributes.size ?? 0),
                        modificationDate: attributes.accessModificationTime?.modificationTime ?? .distantPast
                    ))
                }
            }
        }
        return entries
    }

    public func contentsOfDirectory(at relativePath: String) async throws -> [String] {
        let client = try await connection.client()
        let listing = try await client.listDirectory(atPath: remotePath(relativePath))
        return listing.flatMap(\.components).map(\.filename).filter { $0 != "." && $0 != ".." }
    }

    // MARK: - Metadata

    public func metadata(at relativePath: String) async throws -> VaultFileMetadata {
        let client = try await connection.client()
        guard let attributes = try? await client.getAttributes(at: remotePath(relativePath)) else {
            throw VaultFileSystemError.notFound(relativePath)
        }
        return VaultFileMetadata(
            isRegularFile: Self.isRegularFile(attributes),
            isDirectory: Self.isDirectory(attributes),
            size: Int(attributes.size ?? 0),
            modificationDate: attributes.accessModificationTime?.modificationTime ?? .distantPast
        )
    }

    public func exists(at relativePath: String) async -> Bool {
        guard let client = try? await connection.client() else { return false }
        return (try? await client.getAttributes(at: remotePath(relativePath))) != nil
    }

    // MARK: - Reading

    public func readData(at relativePath: String) async throws -> Data {
        let client = try await connection.client()
        let file = try await client.openFile(filePath: remotePath(relativePath), flags: .read)
        do {
            let buffer = try await file.readAll()
            try await file.close()
            return Data(buffer.readableBytesView)
        } catch {
            try? await file.close()
            throw error
        }
    }

    public func readRange(at relativePath: String, _ range: Range<Int>) async throws -> Data {
        let client = try await connection.client()
        let file = try await client.openFile(filePath: remotePath(relativePath), flags: .read)
        do {
            // SFTP permits SHORT reads — a server caps each SSH_FXP_DATA response (OpenSSH at
            // ~32 KB) regardless of the requested length — so a single read truncates any larger
            // range, and the loopback responder's `partial.count == range.count` check then 500s.
            // Loop, advancing the offset, until the full range is gathered or EOF (empty read).
            var collected = Data()
            var offset = UInt64(range.lowerBound)
            var remaining = range.count
            while remaining > 0 {
                let chunk = try await file.read(
                    from: offset, length: UInt32(min(remaining, Int(UInt32.max))))
                let bytes = Data(chunk.readableBytesView)
                if bytes.isEmpty { break } // EOF / end of file before the range was fully satisfied
                collected.append(bytes)
                offset += UInt64(bytes.count)
                remaining -= bytes.count
            }
            try await file.close()
            return collected
        } catch {
            try? await file.close()
            throw error
        }
    }

    // MARK: - Writing

    public func writeData(_ data: Data, to relativePath: String, options: VaultWriteOptions) async throws {
        let client = try await connection.client()
        let target = remotePath(relativePath)

        if options.contains(.withoutOverwriting),
           (try? await client.getAttributes(at: target)) != nil {
            throw VaultFileSystemError.alreadyExists(relativePath)
        }

        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)

        if options.contains(.atomic) {
            // Write to a sibling temp file, then swap it into place. Plain SFTP rename can't
            // overwrite, so remove the target first (small non-atomic window — hardening TODO).
            let temp = target + ".htmlgraph-tmp-\(UUID().uuidString)"
            let file = try await client.openFile(filePath: temp, flags: [.write, .create, .truncate])
            do {
                try await file.write(buffer)
                try await file.close()
            } catch {
                try? await file.close()
                try? await client.remove(at: temp)
                throw error
            }
            try? await client.remove(at: target)
            try await client.rename(at: temp, to: target)
        } else {
            let file = try await client.openFile(filePath: target, flags: [.write, .create, .truncate])
            do {
                try await file.write(buffer)
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
        }
    }

    // MARK: - Mutations

    public func createDirectory(at relativePath: String) async throws {
        let client = try await connection.client()
        // mkdir -p: create each missing component in turn.
        var partial = ""
        for component in trim(relativePath).split(separator: "/").map(String.init) {
            partial = partial.isEmpty ? component : "\(partial)/\(component)"
            let full = remotePath(partial)
            if (try? await client.getAttributes(at: full)) != nil { continue }
            try? await client.createDirectory(atPath: full)
        }
    }

    public func move(from source: String, to destination: String) async throws {
        let client = try await connection.client()
        try await client.rename(at: remotePath(source), to: remotePath(destination))
    }

    public func copy(from source: String, to destination: String) async throws {
        // SFTP has no server-side copy; stream through the client.
        let data = try await readData(at: source)
        try await writeData(data, to: destination, options: [.atomic])
    }

    public func trash(at relativePath: String) async throws {
        let client = try await connection.client()
        let trashDirectory = "\(VaultIndexExporter.directoryName)/.trash"
        try await createDirectory(at: trashDirectory)
        let name = (relativePath as NSString).lastPathComponent
        var destination = "\(trashDirectory)/\(name)"
        var suffix = 2
        while (try? await client.getAttributes(at: remotePath(destination))) != nil {
            destination = "\(trashDirectory)/\(name).\(suffix)"
            suffix += 1
        }
        try await client.rename(at: remotePath(relativePath), to: remotePath(destination))
    }

    public func remove(at relativePath: String) async throws {
        let client = try await connection.client()
        let full = remotePath(relativePath)
        if let attributes = try? await client.getAttributes(at: full), Self.isDirectory(attributes) {
            try await client.rmdir(at: full)
        } else {
            try await client.remove(at: full)
        }
    }

    // MARK: - Path + attribute helpers

    private func trim(_ relativePath: String) -> String {
        relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Joins a vault-relative path under the remote root.
    private func remotePath(_ relativePath: String) -> String {
        let relative = trim(relativePath)
        return relative.isEmpty ? root : "\(root)/\(relative)"
    }

    private static func normalizeRoot(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    /// POSIX mode-bit checks against `S_IFMT` (0o170000): directory (0o040000), regular file
    /// (0o100000). When the server omits permissions, assume a regular file (not a directory).
    private static func isDirectory(_ attributes: SFTPFileAttributes) -> Bool {
        guard let mode = attributes.permissions else { return false }
        return (mode & 0o170000) == 0o040000
    }

    private static func isRegularFile(_ attributes: SFTPFileAttributes) -> Bool {
        guard let mode = attributes.permissions else { return true }
        return (mode & 0o170000) == 0o100000
    }
}

/// Owns the live `SFTPClient` for one remote vault, reconnecting on demand. An `actor` so the
/// client is created/reused without data races.
actor SFTPConnection {
    private let host: String
    private let port: Int
    private let username: String
    private let credential: SFTPCredential
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?

    init(host: String, port: Int, username: String, credential: SFTPCredential) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
    }

    func client() async throws -> SFTPClient {
        if let sftpClient, sftpClient.isActive { return sftpClient }

        let authentication: SSHAuthenticationMethod
        switch credential {
        case .password(let password):
            authentication = .passwordBased(username: username, password: password)
        }

        let ssh = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: authentication,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        let sftp = try await ssh.openSFTP()
        self.sshClient = ssh
        self.sftpClient = sftp
        return sftp
    }

    func disconnect() async {
        // SFTPClient is Sendable so it can be closed from here; SSHClient is not, so it's just
        // released (its NIO channel tears down on dealloc). Full, prompt SSH-session teardown is
        // a lifecycle/hardening TODO once AppState drives remote vault open/close.
        try? await sftpClient?.close()
        sftpClient = nil
        sshClient = nil
    }
}
