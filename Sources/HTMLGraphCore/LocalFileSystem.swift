import Foundation

/// The reference `VaultFileSystem`: a vault rooted at a local directory URL, backed by
/// `FileManager`. Behavior-preserving — every operation mirrors what the app did before the
/// abstraction (same `.skipsHiddenFiles` enumeration, same `Data`/`String(contentsOf:)`
/// reads, same atomic temp+rename writes, same `FileManager.trashItem`).
///
/// `Sendable` value type holding only a `URL`; it accesses `FileManager.default` inside each
/// method rather than storing it. Its methods are `nonisolated async`, so a call from
/// `@MainActor` runs the blocking `FileManager` work off the main thread on the cooperative
/// pool — no explicit dispatch needed.
public struct LocalFileSystem: VaultFileSystem {
    /// The vault root. Standardized once so relative-path math is stable.
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// The standardized root path — matches the `vaultURL.standardizedFileURL.path` the
    /// indexer used as `VaultIndex.vaultId` before the abstraction.
    public var vaultIdentity: String { root.path }

    public var displayName: String {
        let last = root.lastPathComponent
        return last.isEmpty ? root.path : last
    }

    public var displaySubtitle: String? { root.path }

    // MARK: - Path resolution + containment

    /// Symlink-resolved boundary check, reused for every resolve. Matches the containment the
    /// app enforced through `VaultSecurityPolicy.allows` before this file-system seam existed.
    private static let containment = VaultSecurityPolicy(mode: .safe, allowsNetworkAccess: false)

    /// Resolves a vault-relative, "/"-separated path to an absolute URL under `root`,
    /// rejecting any `..` escape with `outsideVault`. `""` resolves to the root itself.
    ///
    /// Defense in depth: a `..`-free path can still escape via a symlink *inside* the vault
    /// (e.g. `link -> /etc`). After building the URL we verify its symlink-resolved location is
    /// still under the (also-resolved) root, restoring the boundary `VaultSecurityPolicy.allows`
    /// enforced at the loopback server + editor before those paths were routed through here.
    private func resolve(_ relativePath: String) throws -> URL {
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.contains("..") else {
            throw VaultFileSystemError.outsideVault(relativePath)
        }
        let url = components.reduce(root) { $0.appendingPathComponent($1) }
        guard Self.containment.allows(url, vaultRoot: root) else {
            throw VaultFileSystemError.outsideVault(relativePath)
        }
        return url
    }

    /// The absolute on-disk path for a vault-relative path. Local-only affordance used to
    /// populate `DocumentNode.absolutePath` and drive Finder/external-editor actions; a
    /// remote backend has no such path.
    public func absolutePath(for relativePath: String) -> String? {
        (try? resolve(relativePath))?.path
    }

    // MARK: - Enumeration

    public func enumerateFiles(under subpath: String) async throws -> [VaultFileEntry] {
        let directory = try resolve(subpath)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let base = root.path
        var entries: [VaultFileEntry] = []
        // `nextObject()` rather than `for-in`: a `DirectoryEnumerator`'s `Sequence`
        // iterator is unavailable from an async context.
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            let relative = String(full.dropFirst(base.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            entries.append(VaultFileEntry(
                relativePath: relative,
                size: values.fileSize ?? 0,
                modificationDate: values.contentModificationDate ?? .distantPast
            ))
        }
        return entries
    }

    public func contentsOfDirectory(at relativePath: String) async throws -> [String] {
        let url = try resolve(relativePath)
        do {
            return try FileManager.default
                .contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .map { $0.lastPathComponent }
        } catch {
            throw mapNotFound(error, url: url, relativePath: relativePath)
        }
    }

    // MARK: - Metadata

    public func metadata(at relativePath: String) async throws -> VaultFileMetadata {
        let url = try resolve(relativePath)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw VaultFileSystemError.notFound(relativePath)
        }
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        )
        return VaultFileMetadata(
            isRegularFile: values.isRegularFile ?? false,
            isDirectory: isDirectory.boolValue,
            size: values.fileSize ?? 0,
            modificationDate: values.contentModificationDate ?? .distantPast
        )
    }

    public func exists(at relativePath: String) async -> Bool {
        guard let url = try? resolve(relativePath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Reading

    public func readData(at relativePath: String) async throws -> Data {
        let url = try resolve(relativePath)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw mapNotFound(error, url: url, relativePath: relativePath)
        }
    }

    public func readRange(at relativePath: String, _ range: Range<Int>) async throws -> Data {
        let url = try resolve(relativePath)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw VaultFileSystemError.notFound(relativePath)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return try handle.read(upToCount: range.count) ?? Data()
    }

    /// Faithful UTF-8 read via `String(contentsOf:)` (matching the indexer/editor exactly,
    /// including its BOM/decoding behavior) rather than the protocol's data-then-decode
    /// default.
    public func readText(at relativePath: String) async throws -> String {
        let url = try resolve(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw mapNotFound(error, url: url, relativePath: relativePath)
        }
    }

    // MARK: - Writing

    public func writeData(_ data: Data, to relativePath: String, options: VaultWriteOptions) async throws {
        let url = try resolve(relativePath)
        var writingOptions: Data.WritingOptions = []
        if options.contains(.atomic) { writingOptions.insert(.atomic) }
        if options.contains(.withoutOverwriting) { writingOptions.insert(.withoutOverwriting) }
        do {
            try data.write(to: url, options: writingOptions)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw VaultFileSystemError.alreadyExists(relativePath)
        }
    }

    public func createDirectory(at relativePath: String) async throws {
        try FileManager.default.createDirectory(at: try resolve(relativePath), withIntermediateDirectories: true)
    }

    public func move(from source: String, to destination: String) async throws {
        try FileManager.default.moveItem(at: try resolve(source), to: try resolve(destination))
    }

    public func copy(from source: String, to destination: String) async throws {
        try FileManager.default.copyItem(at: try resolve(source), to: try resolve(destination))
    }

    public func trash(at relativePath: String) async throws {
        try FileManager.default.trashItem(at: try resolve(relativePath), resultingItemURL: nil)
    }

    public func remove(at relativePath: String) async throws {
        try FileManager.default.removeItem(at: try resolve(relativePath))
    }

    // MARK: - Helpers

    /// Translates a Foundation read error into `notFound` when the file is genuinely absent,
    /// otherwise rethrows the original error untouched.
    private func mapNotFound(_ error: Error, url: URL, relativePath: String) -> Error {
        FileManager.default.fileExists(atPath: url.path)
            ? error
            : VaultFileSystemError.notFound(relativePath)
    }
}
