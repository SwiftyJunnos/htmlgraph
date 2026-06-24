import Foundation

/// Metadata about a single vault entry, addressed by a vault-relative path.
public struct VaultFileMetadata: Equatable, Sendable {
    public let isRegularFile: Bool
    public let isDirectory: Bool
    /// Size in bytes (0 for directories).
    public let size: Int
    public let modificationDate: Date

    public init(isRegularFile: Bool, isDirectory: Bool, size: Int, modificationDate: Date) {
        self.isRegularFile = isRegularFile
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
    }
}

/// A regular file discovered by a recursive enumeration. `relativePath` is vault-relative
/// and "/"-separated — the same identity the app uses for a document (`DocumentNode.id`).
/// `size`/`modificationDate` are carried alongside so a consumer needn't re-`stat` each file.
public struct VaultFileEntry: Equatable, Sendable {
    public let relativePath: String
    public let size: Int
    public let modificationDate: Date

    public init(relativePath: String, size: Int, modificationDate: Date) {
        self.relativePath = relativePath
        self.size = size
        self.modificationDate = modificationDate
    }
}

/// How a write should be performed. Each backend maps these to its own
/// durability/exclusivity primitives (local: temp+rename; SFTP: temp + atomic rename +
/// read-back verify).
public struct VaultWriteOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// No partial file is ever observable: the bytes land via a temp file that is then
    /// renamed into place.
    public static let atomic = VaultWriteOptions(rawValue: 1 << 0)
    /// Fail with `alreadyExists` instead of overwriting an existing file. Used for
    /// create-only writes (the agent guide), so the create-only guarantee has no
    /// time-of-check/time-of-use race.
    public static let withoutOverwriting = VaultWriteOptions(rawValue: 1 << 1)
}

/// Conditions every `VaultFileSystem` backend must express identically, so callers can
/// branch on them without knowing which backend is underneath.
public enum VaultFileSystemError: Error, Equatable, Sendable {
    /// No file/directory exists at the path.
    case notFound(String)
    /// A `.withoutOverwriting` write hit an existing file.
    case alreadyExists(String)
    /// The bytes at the path are not valid UTF-8 (from `readText`).
    case notUTF8(String)
    /// The path escapes the vault root (e.g. contains `..`). Never touches storage.
    case outsideVault(String)
}

/// A vault's file storage, abstracted so indexing, preview-serving, and editing run
/// unchanged over the local filesystem today and a remote (SFTP) backend later.
///
/// Every path argument is **vault-relative** and "/"-separated (`""` = the vault root). The
/// conforming instance owns the root and is responsible for containment: a path that escapes
/// the vault must throw `VaultFileSystemError.outsideVault` rather than touch anything.
///
/// Methods are `async` because a remote backend performs network I/O and must never block
/// its caller's actor (notably `@MainActor`). `LocalFileSystem` is the behavior-preserving
/// reference backend; an `SFTPFileSystem` will follow.
public protocol VaultFileSystem: Sendable {
    /// A stable identity string for the vault — used as `VaultIndex.vaultId` and the index
    /// cache key. Local backends use the standardized root path; a remote backend uses a
    /// stable URL like `sftp://user@host/path`.
    var vaultIdentity: String { get }

    /// A short, human-readable name for the vault — its folder name. Drives the window title
    /// and recents/UI labels. Defaults to `vaultIdentity`.
    var displayName: String { get }

    /// A secondary label: the full local path, or `user@host:path` for a remote vault. nil
    /// when there's nothing more to show than `displayName`. Defaults to nil.
    var displaySubtitle: String? { get }

    /// The absolute on-disk path for a vault-relative path, when one meaningfully exists
    /// (local backends). Remote backends return `nil` — there is no local path. Used only
    /// to populate `DocumentNode.absolutePath` (a local convenience for Finder /
    /// external-editor actions); content is always read through the async methods below.
    func absolutePath(for relativePath: String) -> String?

    /// Recursively enumerates **regular files** under `subpath` (`""` = vault root),
    /// skipping hidden files, returning their vault-relative paths with size + mtime. Order
    /// is unspecified — callers sort. A missing `subpath` yields `[]` (not an error),
    /// matching `FileManager.enumerator`'s nil-on-missing-directory behavior.
    func enumerateFiles(under subpath: String) async throws -> [VaultFileEntry]

    /// Immediate child names of a directory (one level, names only — not recursive). Throws
    /// `notFound` if the directory doesn't exist.
    func contentsOfDirectory(at relativePath: String) async throws -> [String]

    /// Metadata for one entry. Throws `notFound` if nothing is there.
    func metadata(at relativePath: String) async throws -> VaultFileMetadata

    /// Whether anything (file or directory) exists at the path.
    func exists(at relativePath: String) async -> Bool

    /// Full contents of a file. Throws `notFound` if absent.
    func readData(at relativePath: String) async throws -> Data

    /// Only `range` bytes (half-open), read via a seek — for HTTP range serving without
    /// loading the whole file. The caller is responsible for clamping `range` to the file
    /// size; a backend reads what it can within the file.
    func readRange(at relativePath: String, _ range: Range<Int>) async throws -> Data

    /// Decoded UTF-8 contents. Throws `notUTF8` on invalid bytes. Defaulted in terms of
    /// `readData`, but a backend may override for faithful decoding.
    func readText(at relativePath: String) async throws -> String

    /// Writes `data` to the path per `options`. Intermediate directories are **not** created
    /// (call `createDirectory` first), matching the existing call sites.
    func writeData(_ data: Data, to relativePath: String, options: VaultWriteOptions) async throws

    /// Writes UTF-8 `text`. Defaulted in terms of `writeData`.
    func writeText(_ text: String, to relativePath: String, options: VaultWriteOptions) async throws

    /// Creates a directory, including intermediate directories. No-op if it already exists.
    func createDirectory(at relativePath: String) async throws

    /// Moves/renames `source` to `destination` (same vault). Parent of `destination` must
    /// already exist.
    func move(from source: String, to destination: String) async throws

    /// Copies `source` to `destination` (same vault). Parent of `destination` must exist.
    func copy(from source: String, to destination: String) async throws

    /// Recoverable delete. Local backends use the user's Trash; a remote backend (no Trash)
    /// relocates into a vault-internal trash area. Callers don't care which.
    func trash(at relativePath: String) async throws

    /// Permanent delete.
    func remove(at relativePath: String) async throws
}

public extension VaultFileSystem {
    /// Remote/non-local backends have no on-disk path by default.
    func absolutePath(for relativePath: String) -> String? { nil }

    var displayName: String { vaultIdentity }
    var displaySubtitle: String? { nil }

    func readText(at relativePath: String) async throws -> String {
        let data = try await readData(at: relativePath)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VaultFileSystemError.notUTF8(relativePath)
        }
        return text
    }

    func writeText(_ text: String, to relativePath: String, options: VaultWriteOptions = [.atomic]) async throws {
        try await writeData(Data(text.utf8), to: relativePath, options: options)
    }
}
