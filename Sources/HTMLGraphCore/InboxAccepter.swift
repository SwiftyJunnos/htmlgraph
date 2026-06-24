import Foundation

public enum InboxAcceptanceError: Error, Equatable, Sendable {
    case sourceOutsideInbox
    case destinationOutsideVault
    case destinationInsideInbox
    case destinationAlreadyExists
}

public struct InboxAccepter {
    public init() {}

    /// Moves an unfiled inbox item to a vault-relative `destination` over `fileSystem`.
    /// Validates: the source is inside `Inbox/`; the destination is inside the vault (no
    /// `..` escape) and NOT inside `Inbox/`; and nothing already exists there. Returns the
    /// destination's vault-relative path.
    @discardableResult
    public func accept(
        _ item: InboxItem,
        toRelativePath destination: String,
        fileSystem: VaultFileSystem
    ) async throws -> String {
        let source = item.path
        guard isInsideInbox(source) else {
            throw InboxAcceptanceError.sourceOutsideInbox
        }

        let cleanDestination = destination.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanDestination.isEmpty,
              !cleanDestination.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw InboxAcceptanceError.destinationOutsideVault
        }
        guard !isInsideInbox(cleanDestination) else {
            throw InboxAcceptanceError.destinationInsideInbox
        }
        guard !(await fileSystem.exists(at: cleanDestination)) else {
            throw InboxAcceptanceError.destinationAlreadyExists
        }

        try await fileSystem.createDirectory(at: (cleanDestination as NSString).deletingLastPathComponent)
        try await fileSystem.move(from: source, to: cleanDestination)
        return cleanDestination
    }

    private func isInsideInbox(_ relativePath: String) -> Bool {
        relativePath == InboxScanner.inboxDirectoryName ||
            relativePath.hasPrefix("\(InboxScanner.inboxDirectoryName)/")
    }
}
